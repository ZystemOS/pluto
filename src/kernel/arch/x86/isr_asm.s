.macro isrGenerator n
    .align 4
    .type isr\n, @function
    .global isr\n
    isr\n:
        cli
        // Push 0 if there is no interrupt error code
        .if (\n != 8 && !(\n >= 10 && \n <= 14) && \n != 17)
            push $0
        .endif
        push $\n
        jmp isrCommonStub
.endmacro

isrCommonStub:
    // Push all the registers
    pusha

    // Push the additional segment regiters
    push    %ds
    push    %es
    push    %fs
    push    %gs

    // Set the kernel data segment
    mov     $0x10, %ax
    mov     %ax, %ds
    mov     %ax, %es
    mov     %ax, %fs
    mov     %ax, %gs

    // Push the stack, this is where all the registers are sported, points the interuptContect
    mov     %esp, %eax
    push    %eax

    // Call the handler
    call isrHandler

    // Pop stack pointer to point to the registers pushed
    pop     %eax

    // Pop segment regiters inorder
    pop     %gs
    pop     %fs
    pop     %es
    pop     %ds

    // Pop all general registers
    popa

    // Pop the error code and interrupt number
    add     $0x8, %esp

    // Pops 5 things at once: cs, eip, eflags, ss, and esp
    iret
.type isrCommonStub, @function

isrGenerator 0
isrGenerator 1
isrGenerator 2
isrGenerator 3
isrGenerator 4
isrGenerator 5
isrGenerator 6
isrGenerator 7
isrGenerator 8
isrGenerator 9
isrGenerator 10
isrGenerator 11
isrGenerator 12
isrGenerator 13
isrGenerator 14
isrGenerator 15
isrGenerator 16
isrGenerator 17
isrGenerator 18
isrGenerator 19
isrGenerator 20
isrGenerator 21
isrGenerator 22
isrGenerator 23
isrGenerator 24
isrGenerator 25
isrGenerator 26
isrGenerator 27
isrGenerator 28
isrGenerator 29
isrGenerator 30
isrGenerator 31
