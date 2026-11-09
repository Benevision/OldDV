/*
 * Minimal process start-up code (equivalent of crt1.10.6.o) used when the
 * Mac binaries are cross-linked on Linux with ld64.lld: the executable gets
 * an LC_UNIXTHREAD entry point (see macho_unixthread.py) because
 * Mac OS X 10.6/10.7 do not know LC_MAIN. Not needed for native builds.
 */
extern const struct mach_header _mh_execute_header;
int NXArgc;
const char **NXArgv;
const char **environ;
const char *__progname;

struct ProgramVars {
    const void *mh;
    int *NXArgcPtr;
    const char ***NXArgvPtr;
    const char ***environPtr;
    const char **__prognamePtr;
};
/* dyld reads this section to initialize libSystem's copies of the vars */
__attribute__((used)) static struct ProgramVars pvars
    __attribute__((section("__DATA,__program_vars"))) = {
    &_mh_execute_header, &NXArgc, &NXArgv, &environ, &__progname
};

extern int main(int, char **, char **, char **);
extern void exit(int) __attribute__((noreturn));

__attribute__((used, noreturn)) void olddv_cstart(long *sp)
{
    int argc = (int)sp[0];
    char **argv = (char **)(sp + 1);
    char **envp = argv + argc + 1;
    char **apple = envp;
    const char *p, *q;
    while (*apple)
        apple++;
    apple++;
    NXArgc = argc;
    NXArgv = (const char **)argv;
    environ = (const char **)envp;
    p = argv[0] ? argv[0] : "";
    __progname = p;
    for (q = p; *q; q++)
        if (*q == '/')
            __progname = q + 1;
    exit(main(argc, argv, envp, apple));
}

__asm__(".text\n"
        ".globl start\n"
        "start:\n"
        "    pushq $0\n"
        "    movq %rsp, %rbp\n"
        "    andq $-16, %rsp\n"
        "    leaq 8(%rbp), %rdi\n"
        "    call _olddv_cstart\n"
        "    hlt\n");
