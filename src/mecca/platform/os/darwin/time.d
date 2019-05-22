module mecca.platform.os.darwin.time;

version (Darwin):
package(mecca):

import mecca.platform.os.darwin.dispatch;

struct Timer
{
@nogc:
nothrow:

    import core.time : Duration;

    alias Callback = extern (C) void function();

    private
    {
        Duration interval;
        Callback callback;

        dispatch_source_t timer;
        dispatch_queue_t queue;
    }

    this(Duration interval, Callback callback)
    in
    {
        assert(callback !is null);
    }
    do
    {
        this.callback = callback;
        this.interval = interval;
    }

    void start() @trusted
    {
        import mecca.log : INFO;

        const interval = this.interval.total!"nsecs";

        queue = dispatch_queue_create("com.github.weka-io.mecca.timer", null);
        timer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, queue
        );

        dispatch_source_set_event_handler_f(timer, &handler);
        dispatch_set_context(timer, &this);
        dispatch_source_set_cancel_handler_f(timer, &cancelHandler);

        INFO!"Hang detector will wake up every %s nsecs"(interval);

        const start = dispatch_time(DISPATCH_TIME_NOW, interval);
        dispatch_source_set_timer(timer, start, interval, 0);

        dispatch_activate(timer);
    }

    void cancel() @trusted
    {
        dispatch_source_cancel(timer);
    }

    bool isSet() const pure @safe
    {
        return timer !is null;
    }

private:

    void release()
    {
        dispatch_release(timer);
        dispatch_release(queue);
    }

    extern (C) static void handler(void* timer)
    {
        (cast(Timer*) timer).callback();
    }

    extern (C) static void cancelHandler(void* timer)
    {
        (cast(Timer*) timer).release();
    }
}

auto calculateCycles()
{
    import core.sys.darwin.mach.kern_return : KERN_SUCCESS;
    import core.sys.posix.time : nanosleep, timespec;
    import core.time: mach_absolute_time, mach_timebase_info_data_t,
        mach_timebase_info;

    import std.exception: enforce, errnoEnforce;
    import std.typecons: tuple;

    import mecca.platform.x86: readTSC;

    const sleepTime = timespec(0, 200_000_000);

    const start = mach_absolute_time();
    const cyc0 = readTSC();
    const rcNanosleep = nanosleep(&sleepTime, null);
    const end = mach_absolute_time();
    const cyc1 = readTSC();

    errnoEnforce(rcNanosleep == 0, "nanosleep"); // we hope we won't be interrupted by a signal here

    const elapsed = end - start;

    mach_timebase_info_data_t timebaseInfo;
    enforce(mach_timebase_info(&timebaseInfo) == KERN_SUCCESS);

    const nsecs = elapsed * timebaseInfo.numer / timebaseInfo.denom;

    const cyclesPerSecond = cast(long)((cyc1 - cyc0) / (nsecs / 1E9));
    const cyclesPerMsec = cyclesPerSecond / 1_000;
    const cyclesPerUsec = cyclesPerSecond / 1_000_000;

    return tuple!("perSecond", "perMsec", "perUsec")(
        cyclesPerSecond, cyclesPerMsec, cyclesPerUsec);
}
