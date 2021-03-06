!
! SYS_SIZE is the number of clicks (16 bytes) to be loaded.
! 0x3000 is 0x30000 bytes = 196kB, more than enough for current
! versions of linux
!
SYSSIZE = 0x3000
!
!	bootsect.s		(C) 1991 Linus Torvalds
!
! bootsect.s is loaded at 0x7c00 by the bios-startup routines, and moves
! iself out of the way to address 0x90000, and jumps there.
!
! It then loads 'setup' directly after itself (0x90200), and the system
! at 0x10000, using BIOS interrupts. 
!
! NOTE! currently system is at most 8*65536 bytes long. This should be no
! problem, even in the future. I want to keep it simple. This 512 kB
! kernel size should be enough, especially as this doesn't contain the
! buffer cache as in minix
!
! The loader has been made as simple as possible, and continuos
! read errors will result in a unbreakable loop. Reboot by hand. It
! loads pretty fast by getting whole sectors at a time whenever possible.

.globl begtext, begdata, begbss, endtext, enddata, endbss
.text
begtext:
.data
begdata:
.bss
begbss:
.text

SETUPLEN = 4				! nr of setup-sectors
BOOTSEG  = 0x07c0			! original address of boot-sector
INITSEG  = 0x9000			! we move boot here - out of the way
SETUPSEG = 0x9020			! setup starts here
SYSSEG   = 0x1000			! system loaded at 0x10000 (65536).
ENDSEG   = SYSSEG + SYSSIZE		! where to stop loading

! ROOT_DEV:	0x000 - same type of floppy as boot.
!		0x301 - first partition on first drive etc
ROOT_DEV = 0x306

entry _start
_start:
	mov	ax,#BOOTSEG   
	mov	ds,ax         ! ds = 0x07c0
	mov	ax,#INITSEG
	mov	es,ax         ! es = 0x9000
	mov	cx,#256       ! cx = 256
	sub	si,si         ! si = 0
	sub	di,di         ! di = 0
	rep               ! while(cx!=0) { cx--; movw es:di ds:si}
	movw
	jmpi	go,INITSEG ! jmpi(segment jump): cs:ip = INITSEG:go = 0x9000:go
go:	mov	ax,cs     ! cs = 0x9000
	mov	ds,ax     ! ds = 0x9000
	mov	es,ax     ! es = 0x9000
! put stack at 0x9ff00.
	mov	ss,ax           ! ss:sp = 0x9000:0xff00
	mov	sp,#0xFF00		! arbitrary value >>512

! load the setup-sectors directly after the bootblock.
! Note that 'es' is already set up.

load_setup:
	mov	dx,#0x0000			! drive 0, head 0
	mov	cx,#0x0002			! sector 2, track 0
	mov	bx,#0x0200			! address = 512, in INITSEG
	mov	ax,#0x0200+SETUPLEN	! service 2, nr of sectors, 
	int	0x13				! read it, int 0x13 ah = 02: read sectors from drive
	jnc	ok_load_setup		! ok - continue
	mov	dx,#0x0000			! drive 0, head 0
	mov	ax,#0x0000			! reset the diskette, int 0x13 ah = 00:reset disk drive
	int	0x13
	j	load_setup

ok_load_setup:

! Get disk drive parameters, specifically nr of sectors/track

	mov	dl,#0x00        ! 0x0 ~ 0x7f表示软盘，0x80 ~ 0xff表示硬盘
	mov	ax,#0x0800		! ah=8 is get drive parameters
	int	0x13            ! int 0x13 ah=8:read drive parameters
	mov	ch,#0x00        ! clear ch=0, get cx=cl=sectors/track
	seg cs              ! use cs = 0x9000
	mov	sectors,cx      ! get sectors/track
	mov	ax,#INITSEG     
	mov	es,ax           ! when return, es has changed

! Print some inane message

	mov	ah,#0x03		! read cursor pos
	xor	bh,bh           ! bh=0:page number
	int	0x10            ! int 0x10 ah=3:Get cursor position and shape
	
	mov	cx,#24          ! string length
	mov	bx,#0x0007		! page 0, attribute 7 (normal), bh=0:page number, bl:color
	mov	bp,#msg1        ! es:bp :Offset of string
	mov	ax,#0x1301		! write string, move cursor
	int	0x10

! ok, we've written the message, now
! we want to load the system (at 0x10000)

	mov	ax,#SYSSEG
	mov	es,ax		! segment of 0x010000
	call	read_it
	call	kill_motor

! After that we check which root-device to use. If the device is
! defined (!= 0), nothing is done and the given device is used.
! Otherwise, either /dev/PS0 (2,28) or /dev/at0 (2,8), depending
! on the number of sectors that the BIOS reports currently.

	seg cs				! only confluent next instruction.
	mov	ax,root_dev
	cmp	ax,#0
	jne	root_defined    ! jne = not equal
	seg cs
	mov	bx,sectors
	mov	ax,#0x0208		! /dev/ps0 - 1.2Mb = 2 * 80 * 15 * 512B = 1200KB = 1.2MB
	cmp	bx,#15
	je	root_defined
	mov	ax,#0x021c		! /dev/PS0 - 1.44Mb = 2 * 80 * 18 * 512B = 1440KB = 1.44MB
	cmp	bx,#18
	je	root_defined
undef_root:
	jmp undef_root
root_defined:
	seg cs
	mov	root_dev,ax

! after that (everyting loaded), we jump to
! the setup-routine loaded directly after
! the bootblock:

	jmpi	0,SETUPSEG

! This routine loads the system at address 0x10000, making sure
! no 64kB boundaries are crossed. We try to load it as fast as
! possible, loading whole tracks whenever we can.
!
! in:	es - starting address segment (normally 0x1000)
!
sread:	.word 1+SETUPLEN	! sectors read of current track
head:	.word 0			! current head
track:	.word 0			! current track

read_it:
	mov ax,es
	test ax,#0x0fff
die:	jne die			! es must be at 64kB boundary
	xor bx,bx		! bx is starting address within segment
rp_read:
	mov ax,es
	cmp ax,#ENDSEG		! have we loaded all yet?
	jb ok1_read
	ret
ok1_read:               ! read sectors
	seg cs
	mov ax,sectors
	sub ax,sread
	mov cx,ax
	shl cx,#9
	add cx,bx
	jnc ok2_read
	je ok2_read
	xor ax,ax
	sub ax,bx           ! 16bit = 64KB; ax - bx = 64KB - bx
	shr ax,#9
ok2_read:
	call read_track
	mov cx,ax
	add ax,sread
	seg cs
	cmp ax,sectors
	jne ok3_read
	mov ax,#1
	sub ax,head
	jne ok4_read
	inc track
ok4_read:
	mov head,ax
	xor ax,ax
ok3_read:
	mov sread,ax
	shl cx,#9
	add bx,cx
	jnc rp_read
	mov ax,es
	add ax,#0x1000
	mov es,ax
	xor bx,bx
	jmp rp_read

read_track:
	push ax
	push bx
	push cx
	push dx
	mov dx,track
	mov cx,sread
	inc cx
	mov ch,dl
	mov dx,head
	mov dh,dl
	mov dl,#0
	and dx,#0x0100
	mov ah,#2
	int 0x13
	jc bad_rt
	pop dx
	pop cx
	pop bx
	pop ax
	ret
bad_rt:	mov ax,#0
	mov dx,#0
	int 0x13
	pop dx
	pop cx
	pop bx
	pop ax
	jmp read_track

!/*
! * This procedure turns off the floppy drive motor, so
! * that we enter the kernel in a known state, and
! * don't have to worry about it later.
! */
kill_motor:
	push dx
	mov dx,#0x3f2
	mov al,#0
	outb
	pop dx
	ret

sectors:
	.word 0

msg1:
	.byte 13,10
	.ascii "Loading system ..."
	.byte 13,10,13,10

.org 508
root_dev:
	.word ROOT_DEV
boot_flag:                   !bootsect's flag, if you don't have, you can't boot your system.
	.word 0xAA55

.text
endtext:
.data
enddata:
.bss
endbss:
