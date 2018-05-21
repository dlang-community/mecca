module mecca.lib.hashing;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

//
// adapted from https://github.com/gchatelet/murmurhash3_d/blob/8cb8ebe284a085abbd1d97eff8f3a3e78a95f995/murmurhash3.d
// can be used in CTFE
//
ulong[2] murmurHash3_128(const(ubyte)[] data, ulong seed1=0, ulong seed2=0) pure nothrow @safe @nogc {
    alias Block = ulong[2];
    enum ulong c1 = 0x87c37b91114253d5;
    enum ulong c2 = 0x4cf5ad432745937f;
    ulong h1 = seed1;
    ulong h2 = seed2;
    ulong k1 = 0;
    ulong k2 = 0;
    ulong size = data.length;

    static T rotl(T)(T x, uint y) pure nothrow @nogc @safe {
        return ((x << y) | (x >> (T.sizeof * 8 - y)));
    }
    static T shuffle(T)(T k, T c1, T c2, ubyte r1) pure nothrow @nogc @safe {
        k *= c1;
        k = rotl(k, r1);
        k *= c2;
        return k;
    }
    static T update(T)(ref T h, T k, T mixWith, T c1, T c2, ubyte r1, ubyte r2, T n) pure nothrow @nogc @safe {
        h ^= shuffle(k, c1, c2, r1);
        h = rotl(h, r2);
        h += mixWith;
        return h * 5 + n;
    }
    static ulong fmix(ulong k) pure nothrow @nogc @safe {
        k ^= k >> 33;
        k *= 0xff51afd7ed558ccd;
        k ^= k >> 33;
        k *= 0xc4ceb9fe1a85ec53;
        k ^= k >> 33;
        return k;
    }

    // 16-byte blocks
    auto blockAligned = data[0 .. ($ / Block.sizeof) * Block.sizeof];
    if (__ctfe) {
        import std.range: chunks;
        foreach(chunk; chunks(blockAligned, Block.sizeof)) {
            ulong b0 = ulong(chunk[0]) | (ulong(chunk[1]) << 8) | (ulong(chunk[2]) << 16) | (ulong(chunk[3]) << 24) | (ulong(chunk[4]) << 32) | (ulong(chunk[5]) << 40) | (ulong(chunk[6]) << 48) | (ulong(chunk[7]) << 56);
            ulong b1 = ulong(chunk[8]) | (ulong(chunk[9]) << 8) | (ulong(chunk[10]) << 16) | (ulong(chunk[11]) << 24) | (ulong(chunk[12]) << 32) | (ulong(chunk[13]) << 40) | (ulong(chunk[14]) << 48) | (ulong(chunk[15]) << 56);
            h1 = update(h1, b0, h2, c1, c2, 31, 27, 0x52dce729U);
            h2 = update(h2, b1, h1, c2, c1, 33, 31, 0x38495ab5U);
        }
    }
    else {
        foreach(b; cast(const(Block)[])blockAligned) {
            h1 = update(h1, b[0], h2, c1, c2, 31, 27, 0x52dce729U);
            h2 = update(h2, b[1], h1, c2, c1, 33, 31, 0x38495ab5U);
        }
    }

    // remainder
    auto remainder = data[blockAligned.length .. $];
    assert(remainder.length < Block.sizeof);
    assert(remainder.length >= 0);

    final switch (remainder.length) {
        case 15:
            k2 ^= ulong(remainder[14]) << 48;
            goto case;
        case 14:
            k2 ^= ulong(remainder[13]) << 40;
            goto case;
        case 13:
            k2 ^= ulong(remainder[12]) << 32;
            goto case;
        case 12:
            k2 ^= ulong(remainder[11]) << 24;
            goto case;
        case 11:
            k2 ^= ulong(remainder[10]) << 16;
            goto case;
        case 10:
            k2 ^= ulong(remainder[9]) << 8;
            goto case;
        case 9:
            k2 ^= ulong(remainder[8]) << 0;
            h2 ^= shuffle(k2, c2, c1, 33);
            goto case;
        case 8:
            k1 ^= ulong(remainder[7]) << 56;
            goto case;
        case 7:
            k1 ^= ulong(remainder[6]) << 48;
            goto case;
        case 6:
            k1 ^= ulong(remainder[5]) << 40;
            goto case;
        case 5:
            k1 ^= ulong(remainder[4]) << 32;
            goto case;
        case 4:
            k1 ^= ulong(remainder[3]) << 24;
            goto case;
        case 3:
            k1 ^= ulong(remainder[2]) << 16;
            goto case;
        case 2:
            k1 ^= ulong(remainder[1]) << 8;
            goto case;
        case 1:
            k1 ^= ulong(remainder[0]) << 0;
            h1 ^= shuffle(k1, c1, c2, 31);
            goto case;
        case 0:
    }

    // finalize
    h1 ^= size;
    h2 ^= size;

    h1 += h2;
    h2 += h1;
    h1 = fmix(h1);
    h2 = fmix(h2);
    h1 += h2;
    h2 += h1;

    ulong[2] res = [h1, h2];
    return res;
}

ulong murmurHash3_64(const(ubyte)[] data) pure nothrow @safe @nogc {
    return murmurHash3_128(data)[0];
}
ulong murmurHash3_64(string data) pure nothrow @safe @nogc {
    return murmurHash3_64(cast(const(ubyte)[])data);
}

ubyte[16] murmurHash3_128_ubytes(const(ubyte)[] data) pure nothrow @safe @nogc {
    if (__ctfe) {
        ulong[2] tmp = murmurHash3_128(data);
        ubyte[16] res = [
            tmp[0]         & 0xff,
            (tmp[0] >> 8)  & 0xff,
            (tmp[0] >> 16) & 0xff,
            (tmp[0] >> 24) & 0xff,
            (tmp[0] >> 32) & 0xff,
            (tmp[0] >> 40) & 0xff,
            (tmp[0] >> 48) & 0xff,
            (tmp[0] >> 56) & 0xff,
             tmp[1]        & 0xff,
            (tmp[1] >> 8)  & 0xff,
            (tmp[1] >> 16) & 0xff,
            (tmp[1] >> 24) & 0xff,
            (tmp[1] >> 32) & 0xff,
            (tmp[1] >> 40) & 0xff,
            (tmp[1] >> 48) & 0xff,
            (tmp[1] >> 56) & 0xff,
        ];
        return res;
    }
    else {
        return cast(ubyte[16])murmurHash3_128(data);
    }
}
ubyte[16] murmurHash3_128_ubytes(string data) pure nothrow @safe @nogc {
    return murmurHash3_128_ubytes(cast(const(ubyte)[])data);
}

unittest {
    import std.conv: hexString;
    static assert (murmurHash3_128_ubytes("abcdefghijklmnopqrstuvwxyz") ==
        cast(ubyte[])hexString!"A94A6F517E9D9C7429D5A7B6899CADE9");

    foreach(inp, outp; ["" : hexString!"00000000000000000000000000000000",
                        "a" : hexString!"897859F6655555855A890E51483AB5E6",
                        "ab" : hexString!"2E1BED16EA118B93ADD4529B01A75EE6",
                        "abc" : hexString!"6778AD3F3F3F96B4522DCA264174A23B",
                        "abcd" : hexString!"4FCD5646D6B77BB875E87360883E00F2",
                        "abcde" : hexString!"B8BB96F491D036208CECCF4BA0EEC7C5",
                        "abcdef" : hexString!"55BFA3ACBF867DE45C842133990971B0",
                        "abcdefg" : hexString!"99E49EC09F2FCDA6B6BB55B13AA23A1C",
                        "abcdefgh" : hexString!"028CEF37B00A8ACCA14069EB600D8948",
                        "abcdefghi" : hexString!"64793CF1CFC0470533E041B7F53DB579",
                        "abcdefghij" : hexString!"998C2F770D5BC1B6C91A658CDC854DA2",
                        "abcdefghijk" : hexString!"029D78DFB8D095A871E75A45E2317CBB",
                        "abcdefghijkl" : hexString!"94E17AE6B19BF38E1C62FF7232309E1F",
                        "abcdefghijklm" : hexString!"73FAC0A78D2848167FCCE70DFF7B652E",
                        "abcdefghijklmn" : hexString!"E075C3F5A794D09124336AD2276009EE",
                        "abcdefghijklmno" : hexString!"FB2F0C895124BE8A612A969C2D8C546A",
                        "abcdefghijklmnop" : hexString!"23B74C22A33CCAC41AEB31B395D63343",
                        "abcdefghijklmnopq" : hexString!"57A6BD887F746475E40D11A19D49DAEC",
                        "abcdefghijklmnopqr" : hexString!"508A7F90EC8CF0776BC7005A29A8D471",
                        "abcdefghijklmnopqrs" : hexString!"886D9EDE23BC901574946FB62A4D8AA6",
                        "abcdefghijklmnopqrst" : hexString!"F1E237F926370B314BD016572AF40996",
                        "abcdefghijklmnopqrstu" : hexString!"3CC9FF79E268D5C9FB3C9BE9C148CCD7",
                        "abcdefghijklmnopqrstuv" : hexString!"56F8ABF430E388956DA9F4A8741FDB46",
                        "abcdefghijklmnopqrstuvw" : hexString!"8E234F9DBA0A4840FFE9541CEBB7BE83",
                        "abcdefghijklmnopqrstuvwx" : hexString!"F72CDED40F96946408F22153A3CF0F79",
                        "abcdefghijklmnopqrstuvwxy" : hexString!"0F96072FA4CBE771DBBD9E398115EEED",
                        "abcdefghijklmnopqrstuvwxyz" : hexString!"A94A6F517E9D9C7429D5A7B6899CADE9"]) {
        assert(murmurHash3_128_ubytes(inp) == cast(ubyte[])outp, inp);
    }
}


