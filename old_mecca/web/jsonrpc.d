module mecca.web.jsonrpc;

import mecca.reactor.reactor;
import mecca.web.http;

/++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
rpc call with positional parameters:
    --> {"jsonrpc": "2.0", "method": "subtract", "params": [42, 23], "id": 1}
    <-- {"jsonrpc": "2.0", "result": 19, "id": 1}

    --> {"jsonrpc": "2.0", "method": "subtract", "params": [23, 42], "id": 2}
    <-- {"jsonrpc": "2.0", "result": -19, "id": 2}

rpc call with named parameters:
    --> {"jsonrpc": "2.0", "method": "subtract", "params": {"subtrahend": 23, "minuend": 42}, "id": 3}
    <-- {"jsonrpc": "2.0", "result": 19, "id": 3}

    --> {"jsonrpc": "2.0", "method": "subtract", "params": {"minuend": 42, "subtrahend": 23}, "id": 4}
    <-- {"jsonrpc": "2.0", "result": 19, "id": 4}

a Notification:
    --> {"jsonrpc": "2.0", "method": "update", "params": [1,2,3,4,5]}
    --> {"jsonrpc": "2.0", "method": "foobar"}

rpc call of non-existent method:
    --> {"jsonrpc": "2.0", "method": "foobar", "id": "1"}
    <-- {"jsonrpc": "2.0", "error": {"code": -32601, "message": "Method not found"}, "id": "1"}

rpc call with invalid JSON:
    --> {"jsonrpc": "2.0", "method": "foobar, "params": "bar", "baz]
    <-- {"jsonrpc": "2.0", "error": {"code": -32700, "message": "Parse error"}, "id": null}

rpc call with invalid Request object:
    --> {"jsonrpc": "2.0", "method": 1, "params": "bar"}
    <-- {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": null}

rpc call Batch, invalid JSON:
    --> [
      {"jsonrpc": "2.0", "method": "sum", "params": [1,2,4], "id": "1"},
      {"jsonrpc": "2.0", "method"
    ]
    <-- {"jsonrpc": "2.0", "error": {"code": -32700, "message": "Parse error"}, "id": null}

rpc call with an empty Array:
    --> []
    <-- {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": null}
++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++/

struct JsonRPCContext {
    HttpRequestParser* req;
    HttpResponseBuilder* resp;
    
    void emitMultipart() {
        
    }
}


struct JsonRPCClient {
    
}

struct JsonRPCServer {
    string[string] methods;
    
    void registerMethod(string name) {
    }
    
    void dispatch(HttpRequestParser* req, HttpResponseBuilder* resp) {
        
    }
}





