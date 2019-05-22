module mecca.platform.os.linux.ucontext;

version (linux):
version (X86_64)
package(mecca):

import core.sys.posix.ucontext;

private alias gregset_t = typeof(ucontext_t.uc_mcontext.gregs);

// Implements a platform agnostic interface to `ucontext_t`.
struct Ucontext
{
    private ucontext_t context;

nothrow:
@nogc:

    Mcontext uc_mcontext() return
    {
        return Mcontext(&context.uc_mcontext);
    }
}

struct Mcontext
{
    private mcontext_t* context;

nothrow:
@nogc:

    RegisterSet registers()
    {
        return RegisterSet(&context.gregs);
    }
}

struct RegisterSet
{
    private gregset_t* gregs;

nothrow:
@nogc:

    auto rax()
    {
        return (*gregs)[REG_RAX];
    }

    auto rbx()
    {
        return (*gregs)[REG_RBX];
    }

    auto rcx()
    {
        return (*gregs)[REG_RCX];
    }

    auto rdx()
    {
        return (*gregs)[REG_RDX];
    }

    auto rdi()
    {
        return (*gregs)[REG_RDI];
    }

    auto rsi()
    {
        return (*gregs)[REG_RSI];
    }

    auto rbp()
    {
        return (*gregs)[REG_RBP];
    }

    auto rsp()
    {
        return (*gregs)[REG_RSP];
    }

    auto r8()
    {
        return (*gregs)[REG_R8];
    }

    auto r9()
    {
        return (*gregs)[REG_R9];
    }

    auto r10()
    {
        return (*gregs)[REG_R10];
    }

    auto r11()
    {
        return (*gregs)[REG_R11];
    }

    auto r12()
    {
        return (*gregs)[REG_R12];
    }

    auto r13()
    {
        return (*gregs)[REG_R13];
    }

    auto r14()
    {
        return (*gregs)[REG_R14];
    }

    auto r15()
    {
        return (*gregs)[REG_R15];
    }

    auto rip()
    {
        return (*gregs)[REG_RIP];
    }
}
