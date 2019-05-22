/// Bindings for libdispatch (those symbols that are needed).
module mecca.platform.os.darwin.dispatch;

version (Darwin):
package(mecca.platform.os):

import core.stdc.config : c_ulong;

extern (C):

@nogc:
nothrow:

alias dispatch_function_t = void function(void*);
alias dispatch_queue_attr_t = dispatch_queue_attr_s*;
alias dispatch_queue_t = dispatch_queue_s*;
alias dispatch_source_t = dispatch_source_s*;
alias dispatch_source_type_t = const(dispatch_source_type_s)*;
alias dispatch_time_t = ulong;

enum ulong DISPATCH_TIME_NOW = 0;
enum ulong NSEC_PER_SEC	= 1000000000;

enum DISPATCH_TIMER_STRICT = 0x1;
enum DISPATCH_SOURCE_TYPE_TIMER = &_dispatch_source_type_timer;

extern __gshared const dispatch_source_type_s _dispatch_source_type_timer;

struct dispatch_queue_attr_s;
struct dispatch_queue_s;
struct dispatch_source_s;
struct dispatch_source_type_s {} // this is actually an opaque type but D doesn't allow defining variables of opaque types

union dispatch_object_t
{
    dispatch_queue_s* _dq;
    dispatch_source_s* _ds;
}

dispatch_queue_t dispatch_queue_create(
    const char* label,
    dispatch_queue_attr_t attr
);

dispatch_source_t dispatch_source_create (
    dispatch_source_type_t type,
    uint handle,
    c_ulong mask,
    dispatch_queue_t queue
);

void dispatch_source_set_event_handler_f(
    dispatch_source_t source,
    dispatch_function_t handler
);

void dispatch_source_set_cancel_handler_f(
    dispatch_source_t source,
    dispatch_function_t handler
);

dispatch_time_t dispatch_time(dispatch_time_t when, long delta);

void dispatch_source_set_timer(
    dispatch_source_t source,
    dispatch_time_t start,
    ulong interval,
    ulong leeway
);

void dispatch_activate(dispatch_source_t object);
void dispatch_source_cancel(dispatch_source_t source);

void dispatch_release(dispatch_object_t);

extern (D) void dispatch_release(dispatch_queue_t queue)
{
    dispatch_object_t object = { _dq: queue };
    dispatch_release(object);
}

extern (D) void dispatch_release(dispatch_source_t source)
{
    dispatch_object_t object = { _ds: source };
    dispatch_release(object);
}

void dispatch_set_context(dispatch_source_t object, void* context);
