module mecca.lib.json;

import std.string;
import std.traits;

import mecca.lib.exception;

@("notrace") void traceDisableCompileTimeInstrumentation();


class JsonException: Exception {mixin ExceptionBody;}
class JsonSyntaxException: JsonException {mixin ExceptionBody;}
class JsonParsingException: JsonException {mixin ExceptionBody;}

struct JsonParser {
    char[] buffer;
    size_t offset;
    uint col, row;

    @disable this(this);

    this(char[] buffer) @nogc {
        this.buffer = buffer;
        col = 0;
        row = 1;
        offset = 0;
    }

    private void syntaxError(string msg, uint row_ = -1, uint col_ = -1, string file=__FILE__, size_t line=__LINE__) {
        throw new JsonSyntaxException(msg ~ " (col=%s row=%s)".format(row_ == -1 ? row : row_, col_ == -1 ? col : col_), file, line);
    }
    private void wrongType(string expected, string got, string file=__FILE__, size_t line=__LINE__) {
        throw new JsonParsingException("Expected %s, got %s (col=%s row=%s)".format(expected, got, row, col), file, line);
    }

    private char _read(bool skipWhite, string msg = "Premature termination", uint row_ = -1, uint col_ = -1) {
        if (offset >= buffer.length) {
            syntaxError(msg, row_, col_);
        }
        while (true) {
            auto ch = buffer[offset];
            offset++;
            if (ch == '\n') {
                row++;
                col = 0;
            }
            else {
                col++;
            }
            if (skipWhite && (ch == ' ' || ch == '\t' || ch == '\f' || ch == '\r' || ch == '\n')) {
                continue;
            }
            return ch;
        }
    }

    private char _peek(string msg = "Premature termination") {
        if (offset >= buffer.length) {
            syntaxError("Premature termination", row, col);
        }
        auto tmp = offset;
        while (true) {
            auto ch = buffer[tmp];
            tmp++;
            if (ch == ' ' || ch == '\t' || ch == '\f' || ch == '\r' || ch == '\n') {
                continue;
            }
            return ch;
        }
    }

    void parse(T)(ref T obj) if (__traits(hasMember, T, "fromJson")) {
        obj.fromJson(&this);
    }

    void parse(T)(ref T obj) if (!__traits(hasMember, T, "fromJson")) {
        auto ch = _read(true);

        if (ch == '"') {
            auto startRow = row;
            auto startCol = col;
            auto startOffset = offset;
            size_t shift = 0;

            while (true) {
                ch = _read(false, "Unterminated string", startRow, startCol);
                if (ch == '"') {
                    auto tmp = buffer[startOffset .. offset - 1 - shift];
                    static if (isSomeString!T) {
                        obj = cast(string)tmp;
                    }
                    else static if (__traits(compiles, {obj[0 .. tmp.length] = tmp;})) {
                        static if (__traits(compiles, {obj.length = 0;})) {
                            obj.length = tmp.length;
                        }
                        obj[0 .. tmp.length] = tmp;
                    }
                    else {
                        wrongType(T.stringof, "string");
                    }
                    return;
                }
                else if (ch == '\\') {
                    auto tmpOffset = offset - 1 - shift;
                    ch = _read(false, "Unterminated escape sequence");

                    auto idx = `rnbtf"\\/`.indexOf(ch);
                    if (idx >= 0) {
                        buffer[tmpOffset] = "\r\n\b\t\f\"\\/"[idx];
                        shift++;
                    }
                    else if (ch == 'u') {
                        int val;
                        foreach(i; 0 .. 4) {
                            ch = _read(false, "Unterminated unicode escape sequence");
                            if (ch >= '0' && ch <= '9') {
                                val = val * 16 + (ch - '0');
                            }
                            else if (ch >= 'a' && ch <= 'f') {
                                val = val * 16 + (10 + (ch - 'a'));
                            }
                            else if (ch >= 'A' && ch <= 'F') {
                                val = val * 16 + (10 + (ch - 'A'));
                            }
                            else {
                                syntaxError("Invalid unicode escape sequence: %c".format(ch));
                            }
                        }
                        buffer[tmpOffset] = cast(char)val;
                        shift += 5;
                    }
                    else {
                        syntaxError("Invalid escape sequence \\%c".format(ch));
                    }
                }
                else {
                    buffer[offset-1-shift] = ch;
                }
            }
        }
        else if (ch == 't' && offset + 4 <= buffer.length && buffer[offset .. offset + 4] == "true") {
            static if (isBoolean!T) {
                obj = true;
            }
            else {
                wrongType(T.stringof, "bool");
            }
        }
        else if (ch == 'f' && offset + 5 <= buffer.length && buffer[offset .. offset + 5] == "false") {
            static if (isBoolean!T) {
                obj = false;
            }
            else {
                wrongType(T.stringof, "bool");
            }
        }
        else if (ch == 'n' && offset + 4 <= buffer.length && buffer[offset .. offset + 4] == "null") {
            obj = obj.init;
        }
        else if (ch == '-' || ch >= '0' && ch <= '9') {
            size_t startOffset = offset - 1;
            while (offset < buffer.length) {
                ch = buffer[offset];
                if ((ch >= '0' && ch <= '9') || ch == 'E' || ch == 'e' || ch == '.' || ch == '+' || ch == '-') {
                    _read(false);
                }
                else {
                    break;
                }
            }

            static if (isIntegral!T) {
                import std.conv;
                obj = to!T(buffer[startOffset .. offset]);
            }
            else static if (isFloatingPoint!T) {
                import std.conv;
                obj = to!T(buffer[startOffset .. offset]);
            }
            else {
                wrongType(T.stringof, "integer/floating point");
            }
        }
        else if (ch == '[') {
            static if (isSomeString!T) {
                wrongType(T.stringof, "array");
            }
            else static if (isDynamicArray!T) {
                obj.length = 0;
                while (true) {
                    ch = _peek();
                    if (ch == ']') {
                        _read(true);
                        break;
                    }
                    obj.length++;
                    parse(obj[$-1]);
                    ch = _read(true);
                    if (ch == ',') {
                    }
                    else if (ch == ']') {
                        break;
                    }
                    else {
                        syntaxError("Expected ',' or ']', found '%s'".format(ch));
                    }
                }
            }
            else static if (is(typeof(obj[0]))) {
                size_t index = 0;
                static if (__traits(compiles, {obj.length = 0;})) {
                    obj.length = 0;
                }
                while (true) {
                    ch = _peek();
                    if (ch == ']') {
                        _read(true);
                        break;
                    }
                    static if (__traits(compiles, {obj.length = 0;})) {
                        obj.length = obj.length + 1;
                    }
                    parse(obj[index++]);
                    ch = _read(true);
                    if (ch == ',') {
                    }
                    else if (ch == ']') {
                        break;
                    }
                    else {
                        syntaxError("Expected ',' or ']', found '%s'".format(ch));
                    }
                }
            }
            else {
                wrongType(T.stringof, "array");
            }
        }
        else if (ch == '{') {
            static if (is(T == struct)) {
                while (true) {
                    ch = _peek();
                    if (ch == '}') {
                        _read(true);
                        break;
                    }
                    string k;
                    parse(k);
                    ch = _read(true);
                    if (ch != ':') {
                        syntaxError("Expected ':', found '%s'".format(ch));
                    }
                    _parseIntoStruct(k, obj);
                    ch = _read(true);
                    if (ch == ',') {
                    }
                    else if (ch == '}') {
                        break;
                    }
                    else {
                        syntaxError("Expected ',' or '}', found '%s'".format(ch));
                    }
                }
            }
            else {
                wrongType(T.stringof, "struct");
            }
        }
        else {
            syntaxError("Unexpected character '%s'".format(ch));
            assert(false);
        }
    }

    private void _parseIntoStruct(T)(string name, ref T obj) {
        switch (name) {
            foreach(i, U; typeof(T.tupleof)) {
                case __traits(identifier, T.tupleof[i]):
                    return parse(obj.tupleof[i]);
            }
            default:
                throw new JsonParsingException("Field named '%s' not found in %s".format(name, T.stringof));
        }
    }
}

ref T jsonToObj(T)(string str, ref T obj) {
    return jsonToObj(str.dup, obj);
}

ref T jsonToObj(T)(char[] buffer, ref T obj) {
    auto jp = JsonParser(buffer);
    jp.parse(obj);
    if (jp.buffer[jp.offset .. $].strip.length > 0) {
        throw new JsonParsingException("Trailing data in buffer");
    }
    return obj;
}

struct JsonBuilder {
    char[] buffer;
    size_t offset;
    @disable this(this);

    void emit(T)(auto ref const T obj) {
        static if (__traits(hasMember, T, "toJson")) {
            obj.toJson(&this);
        }
        else static if (is(T == typeof(null))) {
            buffer[offset .. offset + 4] = "null";
            offset += 4;
        }
        else static if (is(T == void*)) {
            assert (obj is null);
            buffer[offset .. offset + 4] = "null";
            offset += 4;
        }
        else static if (isBoolean!T) {
            if (obj) {
                buffer[offset .. offset + 4] = "true";
                offset += 4;
            }
            else {
                buffer[offset .. offset + 5] = "false";
                offset += 5;
            }
        }
        else static if (isIntegral!T) {
            auto used = sformat(buffer[offset .. $], "%d", obj);
            offset += used.length;
        }
        else static if (isFloatingPoint!T) {
            auto used = sformat(buffer[offset .. $], "%f", obj);
            offset += used.length;
        }
        else static if (isSomeString!T) {
            buffer[offset++] = '"';
            foreach(ch; obj) {
                     if (ch == '\t') {buffer[offset++] = '\\'; buffer[offset++] = 't';}
                else if (ch == '\r') {buffer[offset++] = '\\'; buffer[offset++] = 'r';}
                else if (ch == '\n') {buffer[offset++] = '\\'; buffer[offset++] = 'n';}
                else if (ch == '\f') {buffer[offset++] = '\\'; buffer[offset++] = 'f';}
                else if (ch == '\b') {buffer[offset++] = '\\'; buffer[offset++] = 'b';}
                else if (ch == '\"') {buffer[offset++] = '\\'; buffer[offset++] = '"';}
                else if (ch == '\\') {buffer[offset++] = '\\'; buffer[offset++] = '\\';}
                else if (ch == '/')  {buffer[offset++] = '\\'; buffer[offset++] = '/';}
                else if (ch >= 32 && ch < 127) {
                    buffer[offset++] = ch;
                }
                else {
                    auto used = sformat(buffer[offset .. $], "\\u%04x", cast(int)ch);
                    offset += used.length;
                }
            }
            buffer[offset++] = '"';
        }
        else static if (is(T == U[], U)) {
            with (array()) {
                foreach(ref item; obj) {
                    emitItem(item);
                }
            }
        }
        else static if (isAssociativeArray!T) {
            with (object()) {
                foreach(k, const ref v; obj) {
                    emitItem(k, v);
                }
            }
        }
        else static if (__traits(compiles, {foreach(ref x; obj){}})) {
            with (array()) {
                foreach(ref item; obj) {
                    emitItem(item);
                }
            }
        }
        else static if (is(T == struct)) {
            with (object()) {
                foreach(i, U; typeof(T.tupleof)) {
                    emitItem(__traits(identifier, T.tupleof[i]), obj.tupleof[i]);
                }
            }
        }
        else {
            static assert (false, T);
        }
    }

    auto array() {
        static struct ArrayWriter {
            private JsonBuilder* builder;
            @disable this(this);

            private this(JsonBuilder* builder) {
                this.builder = builder;
                builder.buffer[builder.offset++] = '[';
            }
            ~this() {
                if (builder.buffer[builder.offset-1] == ',') {
                    builder.buffer[builder.offset-1] = ']';
                }
                else {
                    builder.buffer[builder.offset++] = ']';
                }
            }
            void emitItem(T)(auto ref const T obj) {
                builder.emit(obj);
                builder.buffer[builder.offset++] = ',';
            }
        }
        return ArrayWriter(&this);
    }

    auto object() {
        static struct ObjectWriter {
            private JsonBuilder* builder;
            @disable this(this);

            private this(JsonBuilder* builder) {
                this.builder = builder;
                builder.buffer[builder.offset++] = '{';
            }
            ~this() {
                if (builder.buffer[builder.offset-1] == ',') {
                    builder.buffer[builder.offset-1] = '}';
                }
                else {
                    builder.buffer[builder.offset++] = '}';
                }
            }
            void emitItem(T)(string name, auto ref const T obj) {
                builder.emit(name);
                builder.buffer[builder.offset++] = ':';
                builder.emit(obj);
                builder.buffer[builder.offset++] = ',';
            }
        }
        return ObjectWriter(&this);
    }

    @property size_t remaining() const {
        return buffer.length - offset;
    }
    @property char[] result() {
        return buffer[0 .. offset];
    }
}

char[] objToJson(T)(auto ref const T obj, char[] buffer) {
    auto jb = JsonBuilder(buffer);
    jb.emit(obj);
    return jb.result;
}


unittest {
    import std.stdio;

    static struct W {
        int a;
        long[] b;
    }

    static struct S {
        int x;
        double y;
        string z;
        W w;
    }
    S s;

    writeln(`{"x": 5, "y": 6.7, "w": {"a": 18, "b": [11,22,33,44,]}, "z": "hel\tlo\u00ff"}`.jsonToObj(s));

    char[100] buf;
    writeln(s.objToJson(buf));
}





