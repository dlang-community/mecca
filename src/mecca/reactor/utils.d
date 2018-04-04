/// Assorted helpers
module mecca.reactor.utils;

import mecca.log;
import mecca.reactor;

/**
 * Pointer to data on another Fiber's stack
 *
 * This is a pointer to data that reside on another fiber's stack. It is assumed that the other fiber knows not
 * to exit the function while the pointer is in effect.
 *
 * This construct protects against the case that the other fiber is killed while the pointer is still live.
 *
 * Params:
 * T = The pointer type to use
 */
struct FiberPointer(T) {
private:
    FiberHandle fibHandle;
    T* ptr;

public:
    /**
     * Construct a FiberPointer.
     */
    this(T* ptr) nothrow @safe @nogc {
        this.fibHandle = theReactor.currentFiberHandle();
        this.ptr = ptr;
    }

    /// Reports whether the pointer is currently valid
    @property bool isValid() const nothrow @safe @nogc {
        return fibHandle.isValid;
    }

    /**
     * Returns the pointer.
     *
     * Returns:
     * Returns the pointer or `null` if the fiber quit
     */
    @property T* get() nothrow @safe @nogc {
        return fibHandle.isValid ? ptr : null;
    }

    /// Return a handle to the owning fiber, if valid
    @property
    auto ownerFiber() const nothrow @safe @nogc {
        assert(this.isValid);
        return this.fibHandle;
    }

    /// Reset the pointer
    @notrace void reset() nothrow @safe @nogc {
        this = FiberPointer.init;
    }

    /// The `FiberPointer` acts as the pointer itself
    alias get this;
}
