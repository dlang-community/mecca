/// allows throttling the rate at which operations are done
module mecca.reactor.sync.throttler;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import mecca.lib.division;
import mecca.lib.exception;
import mecca.lib.time;
import mecca.log;
import mecca.reactor;
import mecca.reactor.sync.fiber_queue;

/**
 * Main throttler implementation
 *
 * Implements <a href="https://en.wikipedia.org/wiki/Token_bucket">Token Bucket</a> QoS. Tokens are deposited into a bucket at a fixed rate.
 * Consumers request withdrawl of tokens from the bucket. If the bucket does not have enough tokens, the request to withdraw is paused until
 * such time as the bucket, again, has enough to allow the request to move forward.
 *
 * The bucket size controls the burst rate, i.e. - the amount of tokens that can be withdrawn without wait after a long quiet period.
 *
 * The throttler is strict first-come first-serve.
 *
 * Params:
 * AllowOverdraft = there are two variants to the throttler. In the first (and default) variant, the tokens ballance must be able to fully
 * cover the current request. The second variant allows a request to proceed even if there is not enough tokens at the moment (overdraw),
 * so long as all previous debt has been repayed.
 */
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
    /**
     * initialize a throttler for use.
     *
     * Params:
     * tokensPerSecond = the rate at which new tokens are deposited at the bucket. Actual rate might vary slightly due to rounding errors.
     * In general, the lower the number, the lower the error.
     * burstSize = the maximal number of tokens that the bucket may hold. Unless overdraft is allowed, this is also the maximal amount
     * that a single withdrawl may request.
     * numInitialTokens = the number of tokens initially in the bucket. If unspecified, the bucket starts out as completely full.
     */
    void open(size_t tokensPerSecond, ulong burstSize) nothrow @safe @nogc {
        open(tokensPerSecond, burstSize, burstSize);
    }

    /// ditto
    void open(size_t tokensPerSecond, ulong burstSize, ulong numInitialTokens) nothrow @safe @nogc {
        ASSERT!"Throttler does not allowg overdraft but has no burst buffer to withdraw from"(burstSize>0 || AllowOverdraft);
        ASSERT!"Can't deposit %s tokens to throttler with burst bucket of %s"
                (numInitialTokens<=cast(long)burstSize, numInitialTokens, burstSize);
        this.burstSize = burstSize;
        tokenBallance = numInitialTokens;
        lastDepositTime = TscTimePoint.hardNow();
        ticksPerToken = TscTimePoint.cyclesPerSecond / tokensPerSecond;
        ticksPerTokenDivider = S64Divisor(ticksPerToken);
    }

    /// Closes the throtller.
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

    /// reports whether open the throttler is open.
    @property bool isOpen() pure const nothrow @safe @nogc {
        return tokenBallance !is tokenBallance.min;
    }

    /**
     * Withdraw tokens from the bucket.
     *
     * Unless AllowOverdraft is true, the amount of tokens requested must be smaller than the burst size. If AllowOverdraft is false and
     * there is insufficient ballance, or if AllowOverdraft is true but the ballance is negative, then the requester is paused until all
     * prior reuqesters have been served $(B and) the ballance is high enough to serve the current request.
     *
     * Params:
     * tokens = number of tokens to withdraw.
     * timeout = sets a timeout for the wait.
     *
     * Throws:
     * TimeoutExpired if the timeout expires.
     *
     * Any other exception injected to this fiber using Reactor.throwInFiber
     */
    void withdraw(ulong tokens, Timeout timeout = Timeout.infinite) @safe @nogc {
        DBG_ASSERT!"Trying to withdraw from close throttler"(isOpen);
        ASSERT!"Trying to withdraw %s tokens from throttler that can only hold %s"(AllowOverdraft || tokens<=burstSize, tokens, burstSize);

        requestedTokens += tokens;
        scope(exit) requestedTokens -= tokens;

        if( requestedTokens > tokens ) {
            // There are other waiters. Wait until this fiber is the next to withdraw
            waiters.suspend(timeout);
        }

        try {
            // We are the first in line to withdraw. No matter why we exit, wake the next in line
            scope(exit) waiters.resumeOne();

            deposit();
            while( !mayWithdraw(tokens) ) {
                theReactor.sleep( calcSleepDuration(tokens, timeout) );
                deposit();
            }

            tokenBallance -= tokens;
        } catch(TimeoutExpired ex) {
            // We know we won't make it even before the timeout actually passes. We delay throwing the reactor timeout until the timeout
            // actually transpired (you never know who depends on this in some weird way), but we do release any other waiter in queue to
            // get a chance at obtaining the lock immediately.
            ERROR!"Fiber will not have enough tokens in time for timeout expirey %s. Wait until it actually expires before throwing"
                    (timeout);
            theReactor.sleep(timeout);
            throw ex;
        }
    }

private:
    void deposit() nothrow @safe @nogc {
        auto now = TscTimePoint.now;
        long cyclesPassed = now.cycles - lastDepositTime.cycles;
        long tokensEarned = cyclesPassed / ticksPerTokenDivider;

        // To avoid drift, effective cycles are only those that earned us whole tokens.
        cyclesPassed = tokensEarned * ticksPerToken;

        lastDepositTime += cyclesPassed;
        tokenBallance += tokensEarned;
        if( tokenBallance>cast(long)(burstSize) )
            tokenBallance = burstSize;
    }

    bool mayWithdraw(ulong tokens) nothrow @safe @nogc {
        return tokenBallance >= (AllowOverdraft ? 0 : cast(long)(tokens));
    }

    Duration calcSleepDuration(ulong tokens, Timeout timeout) @safe @nogc {
        DBG_ASSERT!"calcSleepDuration called, but can withdraw right now"( !mayWithdraw(tokens) );
        long numMissingTokens = (AllowOverdraft ? 0 : tokens) - tokenBallance;
        DBG_ASSERT!"negative missing %s: requested %s have %s"(numMissingTokens>0, numMissingTokens, tokens, tokenBallance);

        auto sleepDuration = TscTimePoint.durationof( numMissingTokens * ticksPerToken );
        if( TscTimePoint.now + sleepDuration > timeout.expiry )
            throw mkEx!TimeoutExpired;
        return sleepDuration;
    }
}

/// Standard throttler. Use this type when applicable.
alias Throttler = ThrottlerImpl!false;
/// Throttler allowing overdrawing tokens.
alias ThrottlerOverdraft = ThrottlerImpl!true;

unittest {
    import std.uuid;
    import std.string : format;

    import mecca.reactor: testWithReactor, theReactor;
    import mecca.reactor.sync.barrier;

    Throttler budget;
    uint numDone;
    Barrier doneEvent;

    enum NETWORK_BUDGET = 12800;

    void loader(uint NUM_PAGES, uint NUM_ITERATIONS)() {
        foreach(iteration; 0..NUM_ITERATIONS) {
            budget.withdraw(NUM_PAGES);
            theReactor.yield();
        }

        numDone++;
        doneEvent.markDone();
    }

    testWithReactor({
        auto startTime = TscTimePoint.hardNow();
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
        auto endTime = TscTimePoint.hardNow();

        auto duration = endTime - startTime;

        DEBUG!"Test took %s"(duration.toString());
        assert( duration>=dur!"msecs"(1900), format("Test should take no less than 1.9 seconds, took %s", duration.toString()) );
        assert( (endTime-startTime)<dur!"msecs"(2200), format("Test should take no more than 2.2 seconds, took %s",
                    duration.toString()) );
    });
}
