/**
 * Library for efficient integer division by a single divider
 *
 * When repeatedly dividing (with integer arithmetics) by the same divider, there are certain tricks that allow
 * for quicker operation that the CPU's divide command. This is payed for by higher computation work during the setup stage.
 *
 * For compile time known values, the compiler already performs this trick. This module is meant for run-time known values
 * that are used repeatedly.
 *
 * This code is a D adaptation of libdivide ($(LINK http://libdivide.com)).
 */

/*
  Copyright (C) 2010 ridiculous_fish libdivide@ridiculousfish.com
  Copyright (C) 2017 Weka.IO
  
  Notice that though the original libdivide is available under either the zlib license or Boost, the D adaptation here
  is only available under the Boost license.

  Please see the AUTHORS file for full copyright and license information.
 */   
module mecca.lib.division;

import std.stdint;

/**
 * Signed 32 bit divisor
 *
 * Simply use on right side of division operation
 */
struct S32Divisor {
    ///
    unittest {
        assert (1000 / S32Divisor(50) == 20);
        // Can be used with CTFE
        static assert (1000 / S32Divisor(50) == 20);
    }

    alias Type = typeof(magic);
    int32_t magic;
    uint8_t more;

    this(int32_t d) {
        assert (d > 0, "d<=0");

        // If d is a power of 2, or negative a power of 2, we have to use a shift.  This is especially
        // important because the magic algorithm fails for -1.  To check if d is a power of 2 or its inverse,
        // it suffices to check whether its absolute value has exactly one bit set.  This works even for INT_MIN,
        // because abs(INT_MIN) == INT_MIN, and INT_MIN has one bit set and is a power of 2.
        uint32_t absD = cast(uint32_t)(d < 0 ? -d : d); //gcc optimizes this to the fast abs trick
        if ((absD & (absD - 1)) == 0) { //check if exactly one bit is set, don't care if absD is 0 since that's divide by zero
            this.magic = 0;
            this.more = cast(uint8_t)(libdivide__count_trailing_zeros32(absD) | (d < 0 ? LIBDIVIDE_NEGATIVE_DIVISOR : 0) | LIBDIVIDE_S32_SHIFT_PATH);
        }
        else {
            const uint32_t floor_log_2_d = cast(uint8_t)(31 - libdivide__count_leading_zeros32(absD));
            assert(floor_log_2_d >= 1);

            uint8_t more;
            //the dividend here is 2**(floor_log_2_d + 31), so the low 32 bit word is 0 and the high word is floor_log_2_d - 1
            uint32_t rem, proposed_m;
            proposed_m = libdivide_64_div_32_to_32(1U << (floor_log_2_d - 1), 0, absD, &rem);
            const uint32_t e = absD - rem;

            /* We are going to start with a power of floor_log_2_d - 1.  This works if works if e < 2**floor_log_2_d. */
            if (e < (1U << floor_log_2_d)) {
                /* This power works */
                more = cast(uint8_t)(floor_log_2_d - 1);
            }
            else {
                // We need to go one higher.  This should not make proposed_m overflow, but it will make it negative
                // when interpreted as an int32_t.
                proposed_m += proposed_m;
                const uint32_t twice_rem = rem + rem;
                if (twice_rem >= absD || twice_rem < rem) proposed_m += 1;
                more = cast(uint8_t)(floor_log_2_d | LIBDIVIDE_ADD_MARKER | (d < 0 ? LIBDIVIDE_NEGATIVE_DIVISOR : 0)); //use the general algorithm
            }
            proposed_m += 1;
            this.magic = (d < 0 ? -cast(int32_t)proposed_m : cast(int32_t)proposed_m);
            this.more = more;
        }
    }

    ref auto opAssign(int32_t d) {
        this.__ctor(d);
        return this;
    }

    int32_t opBinaryRight(string op: "/")(int32_t dividend) const pure nothrow @safe @nogc {
        if (more & LIBDIVIDE_S32_SHIFT_PATH) {
            uint8_t shifter = more & LIBDIVIDE_32_SHIFT_MASK;
            int32_t q = dividend + ((dividend >> 31) & ((1 << shifter) - 1));
            q = q >> shifter;
            int32_t shiftMask = cast(int8_t)(more >> 7); //must be arithmetic shift and then sign-extend
            q = (q ^ shiftMask) - shiftMask;
            return q;
        }
        else {
            int32_t q = libdivide__mullhi_s32(magic, dividend);
            if (more & LIBDIVIDE_ADD_MARKER) {
                int32_t sign = cast(int8_t)(more >> 7); //must be arithmetic shift and then sign extend
                q += ((dividend ^ sign) - sign);
            }
            q >>= more & LIBDIVIDE_32_SHIFT_MASK;
            q += (q < 0);
            return q;
        }
    }
}

/**
 * Unsigned 32 bit divisor
 *
 * Simply use on right side of division operation
 */
struct U32Divisor {
    ///
    unittest {
        assert (1000 / U32Divisor(31) == 32);
        // Can be used with CTFE
        static assert (1000 / U32Divisor(31) == 32);
    }

    alias Type = typeof(magic);
    uint32_t magic;
    uint8_t more;

    this(uint32_t d) {
        assert (d > 0, "d==0");
        if ((d & (d - 1)) == 0) {
            this.magic = 0;
            this.more = cast(uint8_t)(libdivide__count_trailing_zeros32(d) | LIBDIVIDE_U32_SHIFT_PATH);
        }
        else {
            const uint32_t floor_log_2_d = 31 - libdivide__count_leading_zeros32(d);

            uint8_t more;
            uint32_t rem, proposed_m;
            proposed_m = libdivide_64_div_32_to_32(1U << floor_log_2_d, 0, d, &rem);

            assert(rem > 0 && rem < d);
            const uint32_t e = d - rem;

            /* This power works if e < 2**floor_log_2_d. */
            if (e < (1U << floor_log_2_d)) {
                /* This power works */
                more = cast(uint8_t)floor_log_2_d;
            }
            else {
                // We have to use the general 33-bit algorithm.  We need to compute (2**power) / d.
                // However, we already have (2**(power-1))/d and its remainder.  By doubling both, and then
                // correcting the remainder, we can compute the larger division. */
                proposed_m += proposed_m; //don't care about overflow here - in fact, we expect it
                const uint32_t twice_rem = rem + rem;
                if (twice_rem >= d || twice_rem < rem) proposed_m += 1;
                more = cast(uint8_t)(floor_log_2_d | LIBDIVIDE_ADD_MARKER);
            }
            this.magic = 1 + proposed_m;
            this.more = more;
            //result.more's shift should in general be ceil_log_2_d.  But if we used the smaller power, we
            //subtract one from the shift because we're using the smaller power. If we're using the larger power,
            //we subtract one from the shift because it's taken care of by the add indicator.
            //So floor_log_2_d happens to be correct in both cases.
        }
    }

    ref auto opAssign(uint32_t d) {
        this.__ctor(d);
        return this;
    }

    uint32_t opBinaryRight(string op: "/")(uint32_t dividend) const pure nothrow @safe @nogc {
        if (more & LIBDIVIDE_U32_SHIFT_PATH) {
            return dividend >> (more & LIBDIVIDE_32_SHIFT_MASK);
        }
        else {
            uint32_t q = libdivide__mullhi_u32(magic, dividend);
            if (more & LIBDIVIDE_ADD_MARKER) {
                uint32_t t = ((dividend - q) >> 1) + q;
                return t >> (more & LIBDIVIDE_32_SHIFT_MASK);
            }
            else {
                return q >> more; //all upper bits are 0 - don't need to mask them off
            }
        }
    }
}

/**
 * Signed 64 bit divisor
 *
 * Simply use on right side of division operation
 */
struct S64Divisor {
    ///
    unittest {
        assert (1000 / S64Divisor(81) == 12);
        // Can be used with CTFE
        static assert (1000 / S64Divisor(81) == 12);
    }

    alias Type = typeof(magic);
    int64_t magic;
    uint8_t more;

    this(int64_t d) nothrow @trusted @nogc {
        assert (d > 0, "d<=0");
        // If d is a power of 2, or negative a power of 2, we have to use a shift.  This is especially important
        // because the magic algorithm fails for -1.  To check if d is a power of 2 or its inverse, it suffices
        // to check whether its absolute value has exactly one bit set.  This works even for INT_MIN,
        // because abs(INT_MIN) == INT_MIN, and INT_MIN has one bit set and is a power of 2.
        const uint64_t absD = cast(uint64_t)(d < 0 ? -d : d); //gcc optimizes this to the fast abs trick
        if ((absD & (absD - 1)) == 0) { //check if exactly one bit is set, don't care if absD is 0 since that's divide by zero
            this.more = cast(ubyte)(libdivide__count_trailing_zeros64(absD) | (d < 0 ? LIBDIVIDE_NEGATIVE_DIVISOR : 0));
            this.magic = 0;
        }
        else {
            const uint32_t floor_log_2_d = cast(uint32_t)(63 - libdivide__count_leading_zeros64(absD));

            //the dividend here is 2**(floor_log_2_d + 63), so the low 64 bit word is 0 and the high word is floor_log_2_d - 1
            uint8_t more;
            uint64_t rem, proposed_m;
            proposed_m = libdivide_128_div_64_to_64(1UL << (floor_log_2_d - 1), 0, absD, &rem); // XXX This line is not @safe
            const uint64_t e = absD - rem;

            /* We are going to start with a power of floor_log_2_d - 1.  This works if works if e < 2**floor_log_2_d. */
            if (e < (1UL << floor_log_2_d)) {
                /* This power works */
                more = cast(ubyte)(floor_log_2_d - 1);
            }
            else {
                // We need to go one higher.  This should not make proposed_m overflow, but it will make it
                // negative when interpreted as an int32_t.
                proposed_m += proposed_m;
                const uint64_t twice_rem = rem + rem;
                if (twice_rem >= absD || twice_rem < rem) proposed_m += 1;
                more = cast(ubyte)(floor_log_2_d | LIBDIVIDE_ADD_MARKER | (d < 0 ? LIBDIVIDE_NEGATIVE_DIVISOR : 0));
            }
            proposed_m += 1;
            this.more = more;
            this.magic = (d < 0 ? -cast(int64_t)proposed_m : cast(int64_t)proposed_m);
        }
    }

    ref auto opAssign(int64_t d) {
        this.__ctor(d);
        return this;
    }

    int64_t opBinaryRight(string op: "/")(int64_t dividend) const pure nothrow @safe @nogc {
        if (magic == 0) { //shift path
            uint32_t shifter = more & LIBDIVIDE_64_SHIFT_MASK;
            int64_t q = dividend + ((dividend >> 63) & ((1L << shifter) - 1));
            q = q >> shifter;
            int64_t shiftMask = cast(int8_t)(more >> 7); //must be arithmetic shift and then sign-extend
            q = (q ^ shiftMask) - shiftMask;
            return q;
        }
        else {
            int64_t q = libdivide__mullhi_s64(magic, dividend);
            if (more & LIBDIVIDE_ADD_MARKER) {
                int64_t sign = cast(int8_t)(more >> 7); //must be arithmetic shift and then sign extend
                q += ((dividend ^ sign) - sign);
            }
            q >>= more & LIBDIVIDE_64_SHIFT_MASK;
            q += (q < 0);
            return q;
        }
    }
}

/**
 * Unsigned 64 bit divisor
 *
 * Simply use on right side of division operation
 */
struct U64Divisor {
    ///
    unittest {
        assert (1_000_000_000_000 / S64Divisor(1783) == 560_852_495);
        // Can be used with CTFE
        static assert (1_000_000_000_000 / S64Divisor(1783) == 560_852_495);
    }

    alias Type = typeof(magic);
    uint64_t magic;
    uint8_t more;

    this(uint64_t d) {
        assert (d > 0, "d==0");
        if ((d & (d - 1)) == 0) {
            this.more = cast(uint8_t)(libdivide__count_trailing_zeros64(d) | LIBDIVIDE_U64_SHIFT_PATH);
            this.magic = 0;
        }
        else {
            const uint32_t floor_log_2_d = 63 - libdivide__count_leading_zeros64(d);

            uint64_t proposed_m, rem;
            uint8_t more;
            proposed_m = libdivide_128_div_64_to_64(1UL << floor_log_2_d, 0, d, &rem); //== (1 << (64 + floor_log_2_d)) / d

            assert(rem > 0 && rem < d);
            const uint64_t e = d - rem;

            /* This power works if e < 2**floor_log_2_d. */
            if (e < (1UL << floor_log_2_d)) {
                /* This power works */
                more = cast(uint8_t)floor_log_2_d;
            }
            else {
                // We have to use the general 65-bit algorithm.  We need to compute (2**power) / d. However,
                // we already have (2**(power-1))/d and its remainder.  By doubling both, and then correcting
                // the remainder, we can compute the larger division.
                proposed_m += proposed_m; //don't care about overflow here - in fact, we expect it
                const uint64_t twice_rem = rem + rem;
                if (twice_rem >= d || twice_rem < rem) proposed_m += 1;
                more = cast(uint8_t)(floor_log_2_d | LIBDIVIDE_ADD_MARKER);
            }
            this.magic = 1 + proposed_m;
            this.more = more;
            //result.more's shift should in general be ceil_log_2_d.  But if we used the smaller power, we subtract
            //one from the shift because we're using the smaller power. If we're using the larger power, we subtract
            //one from the shift because it's taken care of by the add indicator.  So floor_log_2_d happens to be
            //correct in both cases, which is why we do it outside of the if statement.
        }
    }

    ref auto opAssign(uint64_t d) {
        this.__ctor(d);
        return this;
    }

    uint64_t opBinaryRight(string op: "/")(uint64_t dividend) const pure nothrow @safe @nogc {
        if (more & LIBDIVIDE_U64_SHIFT_PATH) {
            return dividend >> (more & LIBDIVIDE_64_SHIFT_MASK);
        }
        else {
            uint64_t q = libdivide__mullhi_u64(magic, dividend);
            if (more & LIBDIVIDE_ADD_MARKER) {
                uint64_t t = ((dividend - q) >> 1) + q;
                return t >> (more & LIBDIVIDE_64_SHIFT_MASK);
            }
            else {
                return q >> more; //all upper bits are 0 - don't need to mask them off
            }
        }
    }
}

/// Automatically selects the correct divisor based on type
auto divisor(T)(T value) {
    static if (is(T == uint32_t)) {
        return U32Divisor(value);
    }
    else static if (is(T == int32_t)) {
        return S32Divisor(value);
    }
    else static if (is(T == uint64_t)) {
        return U64Divisor(value);
    }
    else static if (is(T == int64_t)) {
        return S64Divisor(value);
    }
    else {
        static assert (false, "T must be an int, uint, long, ulong, not " ~ T.stringof);
    }
}

private:
enum {
    LIBDIVIDE_32_SHIFT_MASK = 0x1F,
    LIBDIVIDE_64_SHIFT_MASK = 0x3F,
    LIBDIVIDE_ADD_MARKER = 0x40,
    LIBDIVIDE_U32_SHIFT_PATH = 0x80,
    LIBDIVIDE_U64_SHIFT_PATH = 0x80,
    LIBDIVIDE_S32_SHIFT_PATH = 0x20,
    LIBDIVIDE_NEGATIVE_DIVISOR = 0x80,
}

static int32_t libdivide__count_trailing_zeros32(uint32_t val) pure nothrow @safe @nogc {
    /* Fast way to count trailing zeros */
    //return __builtin_ctz(val);
    /* Dorky way to count trailing zeros.   Note that this hangs for val = 0! */
    int32_t result = 0;
    val = (val ^ (val - 1)) >> 1;  // Set v's trailing 0s to 1s and zero rest
    while (val) {
        val >>= 1;
        result++;
    }
    return result;
}

static int32_t libdivide__count_leading_zeros32(uint32_t val) pure nothrow @safe @nogc {
    /* Fast way to count leading zeros */
    //return __builtin_clz(val);
    /* Dorky way to count leading zeros.  Note that this hangs for val = 0! */
    int32_t result = 0;
    while (! (val & (1U << 31))) {
        val <<= 1;
        result++;
    }
    return result;
}

static uint32_t libdivide_64_div_32_to_32(uint32_t u1, uint32_t u0, uint32_t v, uint32_t *r) pure nothrow @safe @nogc {
//libdivide_64_div_32_to_32: divides a 64 bit uint {u1, u0} by a 32 bit uint {v}.  The result must fit in 32 bits.
//Returns the quotient directly and the remainder in *r
//#if (LIBDIVIDE_IS_X86_64)
//    uint32_t result;
//    __asm__("divl %[v]"
//            : "=a"(result), "=d"(*r)
//            : [v] "r"(v), "a"(u0), "d"(u1)
//            );
//    return result;
//}
//#else
    uint64_t n = ((cast(uint64_t)u1) << 32) | u0;
    uint32_t result = cast(uint32_t)(n / v);
    *r = cast(uint32_t)(n - result * cast(uint64_t)v);
    return result;
//#endif
}

static uint32_t libdivide__mullhi_u32(uint32_t x, uint32_t y) pure nothrow @safe @nogc {
    uint64_t xl = x, yl = y;
    uint64_t rl = xl * yl;
    return cast(uint32_t)(rl >> 32);
}

static int32_t libdivide__count_trailing_zeros64(uint64_t val) pure nothrow @safe @nogc {
    // Fast way to count trailing zeros.  Note that we disable this in 32 bit because gcc does something horrible -
    // it calls through to a dynamically bound function.
    //return __builtin_ctzll(val);
    // Pretty good way to count trailing zeros.  Note that this hangs for val = 0
    assert (val != 0);
    uint32_t lo = val & 0xFFFFFFFF;
    if (lo != 0) return libdivide__count_trailing_zeros32(lo);
    return 32 + libdivide__count_trailing_zeros32(cast(uint32_t) (val >> 32));
}

static int64_t libdivide__mullhi_s64(int64_t x, int64_t y) pure nothrow @safe @nogc {
    static if (is(cent)) {
        cent xl = x, yl = y;
        cent rl = xl * yl;
        return cast(cent)(rl >> 64);
    }
    else {
        //full 128 bits are x0 * y0 + (x0 * y1 << 32) + (x1 * y0 << 32) + (x1 * y1 << 64)
        const uint32_t mask = 0xFFFFFFFF;
        const uint32_t x0 = cast(uint32_t)(x & mask), y0 = cast(uint32_t)(y & mask);
        const int32_t x1 = cast(int32_t)(x >> 32), y1 = cast(int32_t)(y >> 32);
        const uint32_t x0y0_hi = libdivide__mullhi_u32(x0, y0);
        const int64_t t = x1*cast(int64_t)y0 + x0y0_hi;
        const int64_t w1 = x0*cast(int64_t)y1 + (t & mask);
        return x1*cast(int64_t)y1 + (t >> 32) + (w1 >> 32);
    }
}

static int32_t libdivide__mullhi_s32(int32_t x, int32_t y) pure nothrow @safe @nogc {
    int64_t xl = x, yl = y;
    int64_t rl = xl * yl;
    return cast(int32_t)(rl >> 32); //needs to be arithmetic shift
}

static int32_t libdivide__count_leading_zeros64(uint64_t val) pure nothrow @safe @nogc {
    /* Fast way to count leading zeros */
    //return __builtin_clzll(val);
    /* Dorky way to count leading zeros.  Note that this hangs for val = 0! */
    int32_t result = 0;
    while (! (val & (1UL << 63))) {
        val <<= 1;
        result++;
    }
    return result;
}

static uint64_t libdivide_128_div_64_to_64(uint64_t u1, uint64_t u0, uint64_t v, uint64_t *r) pure nothrow @safe @nogc {
    const uint64_t b = (1UL << 32);  // Number base (16 bits).
    uint64_t un1, un0,               // Norm. dividend LSD's.
    vn1, vn0,                        // Norm. divisor digits.
    q1, q0,                          // Quotient digits.
    un64, un21, un10,                // Dividend digit pairs.
    rhat;                            // A remainder.
    int s;                           // Shift amount for norm.

    if (u1 >= v) {                   // If overflow, set rem.
        if (r !is null) {            // to an impossible value,
            *r = cast(uint64_t)(-1); // and return the largest
        }
        else {
            return cast(uint64_t)(-1);    // possible quotient.
        }
    }

    /* count leading zeros */
    s = libdivide__count_leading_zeros64(v); // 0 <= s <= 63.
    if (s > 0) {
        v = v << s;           // Normalize divisor.
        un64 = (u1 << s) | ((u0 >> (64 - s)) & (-s >> 31));
        un10 = u0 << s;       // Shift dividend left.
    }
    else {
        // Avoid undefined behavior.
        un64 = u1 | u0;
        un10 = u0;
    }

    vn1 = v >> 32;            // Break divisor up into
    vn0 = v & 0xFFFFFFFF;     // two 32-bit digits.

    un1 = un10 >> 32;         // Break right half of
    un0 = un10 & 0xFFFFFFFF;  // dividend into two digits.

    q1 = un64/vn1;            // Compute the first
    rhat = un64 - q1*vn1;     // quotient digit, q1.
again1:
    if (q1 >= b || q1*vn0 > b*rhat + un1) {
        q1 = q1 - 1;
        rhat = rhat + vn1;
        if (rhat < b) goto again1;
    }

    un21 = un64*b + un1 - q1*v;  // Multiply and subtract.

    q0 = un21/vn1;            // Compute the second
    rhat = un21 - q0*vn1;     // quotient digit, q0.
again2:
    if (q0 >= b || q0*vn0 > b*rhat + un0) {
        q0 = q0 - 1;
        rhat = rhat + vn1;
        if (rhat < b) goto again2;
    }

    if (r !is null) {           // If remainder is wanted,
        *r = (un21*b + un0 - q0*v) >> s;     // return it.
    }
    return q1*b + q0;
}

static uint64_t libdivide__mullhi_u64(uint64_t x, uint64_t y) pure nothrow @safe @nogc {
    static if (is(ucent)) {
        ucent xl = x, yl = y;
        ucent rl = xl * yl;
        return cast(ucent)(rl >> 64);
    }
    else {
        //full 128 bits are x0 * y0 + (x0 * y1 << 32) + (x1 * y0 << 32) + (x1 * y1 << 64)
        const uint32_t mask = 0xFFFFFFFF;
        const uint32_t x0 = cast(uint32_t)(x & mask), x1 = cast(uint32_t)(x >> 32);
        const uint32_t y0 = cast(uint32_t)(y & mask), y1 = cast(uint32_t)(y >> 32);
        const uint32_t x0y0_hi = libdivide__mullhi_u32(x0, y0);
        const uint64_t x0y1 = x0 * cast(uint64_t)y1;
        const uint64_t x1y0 = x1 * cast(uint64_t)y0;
        const uint64_t x1y1 = x1 * cast(uint64_t)y1;

        uint64_t temp = x1y0 + x0y0_hi;
        uint64_t temp_lo = temp & mask, temp_hi = temp >> 32;
        return x1y1 + temp_hi + ((temp_lo + x0y1) >> 32);
    }
}

unittest {
    import std.random;
    import std.string;
    import std.typetuple;

    int counter;
    alias divisors = TypeTuple!(S32Divisor, U32Divisor, S64Divisor, U64Divisor);
    enum tests = 5000;

    foreach(D; divisors) {
        foreach(j; 0 .. tests) {
            D.Type d = uniform(1, D.Type.max);
            D.Type n = uniform(D.Type.min, D.Type.max);
            D.Type q = n / d;

            D d2 = D(d);
            D.Type q2 = n / d2;
            assert (q == q2, "%s/%s = %s, not %s".format(n, d, q, q2));
            counter++;
        }
    }
    assert(counter == divisors.length * tests, "counter=%s".format(counter));
}
