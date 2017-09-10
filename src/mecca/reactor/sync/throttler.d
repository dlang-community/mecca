module mecca.reactor.sync.throttler;

import mecca.lib.division;
import mecca.lib.exception;
import mecca.lib.time;
import mecca.log;
import mecca.reactor;
import mecca.reactor.sync.fiber_queue;

struct ThrottlerImpl(bool AllowOverdraft = false) {
private:
    long tokenBallance = tokenBallance.min; // Can be negative IFF AllowOverdraft is true
    TscTimePoint lastDepositTime;
    ulong ticksPerToken;
    S64Divisor ticksPerTokenDivider;
    FiberQueue waiters;
    ulong burstSize;
    ulong requestedTokens;

public:
    void open(size_t tokensPerSecond, ulong burstSize) nothrow @safe @nogc {
        open(tokensPerSecond, burstSize, burstSize);
    }

    /// ditto
    void open(size_t tokensPerSecond, ulong burstSize, ulong numInitialTokens) nothrow @safe @nogc {
        ASSERT!"Throttler does not allowg overdraft but has no burst buffer to withdraw from"(burstSize>0 || AllowOverdraft);
        ASSERT!"Can't deposit %s tokens to throttler with burst bucket of %s"(numInitialTokens<=burstSize, numInitialTokens, burstSize);
        this.burstSize = burstSize;
        tokenBallance = numInitialTokens;
        lastDepositTime = TscTimePoint.now();
        ticksPerToken = TscTimePoint.cyclesPerSecond / tokensPerSecond;
        ticksPerTokenDivider = S64Divisor(ticksPerToken);
    }

    void close() nothrow @safe @nogc {
        if( !isOpen )
            return;

        waiters.resumeAll();
        lastDepositTime = TscTimePoint.min;
        tokenBallance = tokenBallance.min;
    }

    ~this() nothrow @safe @nogc {
        ASSERT!"open throttler destructed"( !isOpen );
    }

    @property bool isOpen() pure const nothrow @safe @nogc {
        return tokenBallance !is tokenBallance.min;
    }

    void withdraw(ulong tokens) @safe @nogc {
        DBG_ASSERT!"Trying to withdraw from close throttler"(isOpen);
        ASSERT!"Trying to withdraw %s tokens from throttler that can only hold %s"(AllowOverdraft || tokens<burstSize, tokens, burstSize);

        requestedTokens += tokens;
        scope(exit) requestedTokens -= tokens;

        if( requestedTokens > tokens ) {
            // There are other waiters. Wait until this fiber is the next to withdraw
            waiters.suspend();
        }

        // We are the first in line to withdraw. No matter why we exit, wake the next in line
        scope(exit) waiters.resumeOne();

        deposit();
        while( !mayWithdraw(tokens) ) {
            theReactor.sleep( calcSleepDuration(tokens) );
            deposit();
        }

        tokenBallance -= tokens;
    }

private:
    void deposit() nothrow @safe @nogc {
        auto now = TscTimePoint.softNow;
        long cyclesPassed = now.cycles - lastDepositTime.cycles;
        long tokensEarned = cyclesPassed / ticksPerTokenDivider;

        // To avoid drift, effective cycles are only those that earned us whole tokens.
        cyclesPassed = tokensEarned * ticksPerToken;

        lastDepositTime += cyclesPassed;
        tokenBallance += tokensEarned;
        if( tokenBallance>burstSize )
            tokenBallance = burstSize;
    }

    bool mayWithdraw(ulong tokens) {
        return tokenBallance >= (AllowOverdraft ? 0 : tokens);
    }

    Duration calcSleepDuration(ulong tokens) {
        DBG_ASSERT!"calcSleepDuration called, but can withdraw right now"( !mayWithdraw(tokens) );
        long numMissingTokens = (AllowOverdraft ? 0 : tokens) - tokenBallance;
        DBG_ASSERT!"negative missing %s: requested %s have %s"(numMissingTokens>0, numMissingTokens, tokens, tokenBallance);

        auto sleepDuration = TscTimePoint.toDuration( numMissingTokens * ticksPerToken );
        return sleepDuration;
    }
}

alias Throttler = ThrottlerImpl!false;
alias ThrottlerOverdraft = ThrottlerImpl!true;

unittest {
    import std.uuid;
    import std.string : format;

    import mecca.reactor.reactor: testWithReactor, theReactor;
    import mecca.reactor.sync.barrier;

    Throttler budget;
    uint numDone;
    Barrier doneEvent;

    enum NETWORK_BUDGET = 12800;

    void loader(uint NUM_PAGES, uint NUM_ITERATIONS)() {
        foreach(iteration; 0..NUM_ITERATIONS) {
            budget.withdraw(NUM_PAGES);
            theReactor.yieldThisFiber();
        }

        numDone++;
        doneEvent.markDone();
    }

    testWithReactor({
        auto startTime = TscTimePoint.now();
        budget.open(NETWORK_BUDGET, 256);
        scope(exit) budget.close();

        theReactor.spawnFiber(&loader!(150, 100)); // Big packets
        doneEvent.addWaiter();
        theReactor.spawnFiber(&loader!(3, 1000)); // Small packets
        doneEvent.addWaiter();
        theReactor.spawnFiber(&loader!(3, 1000)); // Small packets
        doneEvent.addWaiter();
        theReactor.spawnFiber(&loader!(2, 1000)); // Small packets
        doneEvent.addWaiter();
        theReactor.spawnFiber(&loader!(26, 100)); // Medium packets
        doneEvent.addWaiter();
        // All together: 25,600 packets, which at 50MB/s equals two seconds

        doneEvent.waitAll();
        auto endTime = TscTimePoint.now();

        auto duration = endTime - startTime;

        DEBUG!"Test took %s"(duration.toString());
        assert( duration>=dur!"msecs"(1900), format("Test should take no less than 1.9 seconds, took %s", duration.toString()) );
        assert( (endTime-startTime)<dur!"msecs"(2200), format("Test should take no more than 2.2 seconds, took %s",
                    duration.toString()) );
    });
}
