module mecca.platform.os.darwin.ucontext;

version (OSX):
version (X86_64):
package(mecca):

// Implements a platform agnostic interface to `ucontext_t`.
struct Ucontext
{
    private ucontext_t context;

nothrow:
@nogc:

    Mcontext uc_mcontext()
    {
        return Mcontext(context.uc_mcontext);
    }
}

struct Mcontext
{
    private mcontext_t* context;

nothrow:
@nogc:

    RegisterSet registers()
    {
        return RegisterSet(&context.__ss);
    }
}

struct RegisterSet
{
    private __darwin_x86_thread_state64* state;

nothrow:
@nogc:

    auto rax()
    {
        return state.__rax;
    }

    auto rbx()
    {
        return state.__rbx;
    }

    auto rcx()
    {
        return state.__rcx;
    }

    auto rdx()
    {
        return state.__rdx;
    }

    auto rdi()
    {
        return state.__rdi;
    }

    auto rsi()
    {
        return state.__rsi;
    }

    auto rbp()
    {
        return state.__rbp;
    }

    auto rsp()
    {
        return state.__rsp;
    }

    auto r8()
    {
        return state.__r8;
    }

    auto r9()
    {
        return state.__r9;
    }

    auto r10()
    {
        return state.__r10;
    }

    auto r11()
    {
        return state.__r11;
    }

    auto r12()
    {
        return state.__r12;
    }

    auto r13()
    {
        return state.__r13;
    }

    auto r14()
    {
        return state.__r14;
    }

    auto r15()
    {
        return state.__r15;
    }

    auto rip()
    {
        return state.__rip;
    }
}

// bindings
struct ucontext_t
{
    int uc_onstack;
    uint uc_sigmask;
    stack_t uc_stack;
    ucontext_t* uc_link;
    size_t uc_mcsize;
    mcontext_t* uc_mcontext;
}

struct stack_t
{
    void* ss_sp;
    size_t ss_size;
    int ss_flags;
}

struct mcontext_t
{
    __darwin_x86_exception_state64 __es;
    __darwin_x86_thread_state64 __ss;
    __darwin_x86_float_state64 __fs;
}

struct __darwin_x86_exception_state64
{
    ushort __trapno;
    ushort __cpu;
    uint __err;
    ulong __faultvaddr;
}

struct __darwin_x86_thread_state64
{
    ulong __rax;
    ulong __rbx;
    ulong __rcx;
    ulong __rdx;
    ulong __rdi;
    ulong __rsi;
    ulong __rbp;
    ulong __rsp;
    ulong __r8;
    ulong __r9;
    ulong __r10;
    ulong __r11;
    ulong __r12;
    ulong __r13;
    ulong __r14;
    ulong __r15;
    ulong __rip;
    ulong __rflags;
    ulong __cs;
    ulong __fs;
    ulong __gs;
}

struct __darwin_x86_float_state64
{
    int[2] __fpu_reserved;
    __darwin_fp_control __fpu_fcw; // x87 FPU control word
    __darwin_fp_status __fpu_fsw; // x87 FPU status word
    ubyte __fpu_ftw; // x87 FPU tag word
    ubyte __fpu_rsrv1; // reserved
    ushort __fpu_fop; // x87 FPU Opcode

    // x87 FPU Instruction Pointer
    uint __fpu_ip; // offset
    ushort __fpu_cs; // selector

    ushort __fpu_rsrv2; // reserved

    // x87 FPU Instruction Operand(Data) Pointer
    uint __fpu_dp; // offset
    ushort __fpu_ds; // Selector

    ushort __fpu_rsrv3; // reserved
    uint __fpu_mxcsr; // MXCSR Register state
    uint __fpu_mxcsrmask; // MXCSR mask
    __darwin_mmst_reg __fpu_stmm0; // ST0/MM0
    __darwin_mmst_reg __fpu_stmm1; // ST1/MM1
    __darwin_mmst_reg __fpu_stmm2; // ST2/MM2
    __darwin_mmst_reg __fpu_stmm3; // ST3/MM3
    __darwin_mmst_reg __fpu_stmm4; // ST4/MM4
    __darwin_mmst_reg __fpu_stmm5; // ST5/MM5
    __darwin_mmst_reg __fpu_stmm6; // ST6/MM6
    __darwin_mmst_reg __fpu_stmm7; // ST7/MM7
    __darwin_xmm_reg __fpu_xmm0; // XMM 0
    __darwin_xmm_reg __fpu_xmm1; // XMM 1
    __darwin_xmm_reg __fpu_xmm2; // XMM 2
    __darwin_xmm_reg __fpu_xmm3; // XMM 3
    __darwin_xmm_reg __fpu_xmm4; // XMM 4
    __darwin_xmm_reg __fpu_xmm5; // XMM 5
    __darwin_xmm_reg __fpu_xmm6; // XMM 6
    __darwin_xmm_reg __fpu_xmm7; // XMM 7
    __darwin_xmm_reg __fpu_xmm8; // XMM 8
    __darwin_xmm_reg __fpu_xmm9; // XMM 9
    __darwin_xmm_reg __fpu_xmm10; // XMM 10
    __darwin_xmm_reg __fpu_xmm11; // XMM 11
    __darwin_xmm_reg __fpu_xmm12; // XMM 12
    __darwin_xmm_reg __fpu_xmm13; // XMM 13
    __darwin_xmm_reg __fpu_xmm14; // XMM 14
    __darwin_xmm_reg __fpu_xmm15; // XMM 15
    char[6 * 16] __fpu_rsrv4; // reserved
    int __fpu_reserved1;
}

struct __darwin_fp_control
{
    import std.bitmanip : bitfields;

    mixin(bitfields!(
        ushort, "__invalid", 1,
        ushort, "__denorm", 1,
        ushort, "__zdiv", 1,
        ushort, "__ovrfl", 1,
        ushort, "__undfl", 1,
        ushort, "__precis", 1,
        ushort, "", 2,
        ushort, "__pc", 2,
        ushort, "__rc", 2,
        ushort, "", 1,
        ushort, "", 3));
}

struct __darwin_fp_status
{
    import std.bitmanip : bitfields;

    mixin(bitfields!(
        ushort, "__invalid", 1,
        ushort, "__denorm", 1,
        ushort, "__zdiv", 1,
        ushort, "__ovrfl", 1,
        ushort, "__undfl", 1,
        ushort, "__precis", 1,
        ushort, "__stkflt", 1,
        ushort, "__errsumm", 1,
        ushort, "__c0", 1,
        ushort, "__c1", 1,
        ushort, "__c2", 1,
        ushort, "__tos", 3,
        ushort, "__c3", 1,
        ushort, "__busy", 1));
}

struct __darwin_mmst_reg
{
    char[10] __mmst_reg;
    char[6] __mmst_rsrv;
}

struct __darwin_xmm_reg
{
    char[16] __xmm_reg;
}
