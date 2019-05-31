.macro irqGenerator n
    .align 4
    .type irq\n, @function
    .global irq\n
    irq\n:
        cli
        push $0
        push $\n+32
        jmp irqCommonStub
.endmacro

irqCommonStub:
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
    call irqHandler

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
.type irqCommonStub, @function

irqGenerator 0
irqGenerator 1
irqGenerator 2
irqGenerator 3
irqGenerator 4
irqGenerator 5
irqGenerator 6
irqGenerator 7
irqGenerator 8
irqGenerator 9
irqGenerator 10
irqGenerator 11
irqGenerator 12
irqGenerator 13
irqGenerator 14
irqGenerator 15
