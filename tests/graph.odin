package tests

import sb "../src/graph"
import test "core:testing"

setup :: proc(char_bits := u16(8)) -> sb.Graph {
	g: sb.Graph
	g.target.char_bits = char_bits
	g.target.ptr_size = 8
	g.target.syscall_result = sb.type_int(char_bits * 8)
	g.target.endian = .Little
	return g
}

@(test)
type_size :: proc(t: ^test.T) {
	g := setup()
	context.user_ptr = &g

	size :: sb.type_size

	// unit types
	test.expect_value(t, size(sb.type_io()), 0)
	test.expect_value(t, size(sb.type_memory()), 0)
	test.expect_value(t, size(sb.type_control()), 0)
	test.expect_value(t, size(sb.type_unit()), 0)

	// boolean is one character wide
	test.expect_value(t, size(sb.type_bool()), 1)

	// int boundary
	test.expect_value(t, size(sb.type_int(7)), 1)
	test.expect_value(t, size(sb.type_int(8)), 1)
	test.expect_value(t, size(sb.type_int(9)), 2)

	// pointer is 8 characters wide
	test.expect_value(t, size(sb.type_ptr(0)), 8)
}
