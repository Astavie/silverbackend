package sb

import "core:fmt"
import "core:strings"

Data_Type_Enum :: enum u8 {
	// represents the I/O state
	IO,
	// represents the state of memory
	Memory,
	// used in branch and phi nodes
	Control,
	// integers, extra bits denote size: unit type is i0 and bool is i1
	Integer,
	// pointer, extra bits 0..7 for address space, 8..11 for alignment
	Pointer,
}

Data_Type :: struct #raw_union {
	base: bit_field u16 {
		type: Data_Type_Enum | 4,
		_pad: u16 | 12,
	},
	integer: bit_field u16 {
		type: Data_Type_Enum | 4,
		bits: u16 | 12,
	},
	pointer: bit_field u16 {
		type: Data_Type_Enum | 4,
		align_exp: u8 | 4,
		address_space: u8 | 8,
	},
}

type_int :: proc "contextless" (bits: u16) -> Data_Type {
	return { integer = { type = .Integer, bits = bits } }
}

type_ptr :: proc "contextless" (align_exp: u8, address_space: u8) -> Data_Type {
	return { pointer = { type = .Pointer, align_exp = align_exp, address_space = address_space } }
}

// TYPE_IO : Data_Type : { base = { type = .IO } }
// TYPE_MEMORY : Data_Type : { base = { type = .Memory } }
// TYPE_CONTROL : Data_Type : { base = { type = .Control } }

// TYPE_UNIT : Data_Type : { integer = { type = .Integer, bits = 0 } }
// TYPE_BOOL : Data_Type : { integer = { type = .Integer, bits = 1 } }
// TYPE_I8 : Data_Type : { integer = { type = .Integer, bits = 8 } }
// TYPE_I16 : Data_Type : { integer = { type = .Integer, bits = 16 } }
// TYPE_I32 : Data_Type : { integer = { type = .Integer, bits = 32 } }
// TYPE_I64 : Data_Type : { integer = { type = .Integer, bits = 64 } }

type_io :: proc "contextless" () -> Data_Type {
	return { base = { type = .IO } }
}

type_memory :: proc "contextless" () -> Data_Type {
	return { base = { type = .Memory } }
}

type_control :: proc "contextless" () -> Data_Type {
	return { base = { type = .Control } }
}

type_unit :: proc "contextless" () -> Data_Type {
	return { integer = { type = .Integer, bits = 0 } }
}

type_bool :: proc "contextless" () -> Data_Type {
	return { integer = { type = .Integer, bits = 1 } }
}

type_name :: proc(buf: ^strings.Builder, type: Data_Type) {
	switch type.base.type {
	case .IO:
		fmt.sbprint(buf, "i/o")
	case .Memory:
		fmt.sbprint(buf, "memory")
	case .Control:
		fmt.sbprint(buf, "control")
	case .Integer:
		bits := type.integer.bits
		if bits == 0 do fmt.sbprint(buf, "unit")
		else if bits == 1 do fmt.sbprint(buf, "bool")
		else do fmt.sbprintf(buf, "i%d", bits)
	case .Pointer:
		fmt.sbprint(buf, "ptr")
		if type.pointer.align_exp != 0 {
			fmt.sbprintf(buf, " align(%d)", u32(1) << u32(type.pointer.align_exp))
		}
		if type.pointer.address_space != 0 {
			fmt.sbprintf(buf, " addrspace(%d)", type.pointer.address_space)
		}
	}
}

type_size :: proc(type: Data_Type) -> u16 {
	switch type.base.type {
	case .IO:
		return 0
	case .Memory:
		return 0
	case .Control:
		return 0
	case .Integer:
		// TODO: round UP
		return type.integer.bits / backend().target.char_bits
	case .Pointer:
		return backend().target.ptr_size
	}
	return 0
}
