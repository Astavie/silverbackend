package silverbackend

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

import "opt"
import "sb"

main_err :: proc() -> mem.Allocator_Error {
	graph := sb.backend()

	fun := sb.start_function(
		{sb.type_io()},
		{sb.type_io()},
		{name = "_start", linkage = .External},
	) or_return
	start := graph.functions[int(fun)].start

	msg_str := transmute([]u8)string("Hello, World!\n")

	one := sb.push(sb.node_constant(sb.type_int(64), 1)) or_return
	msg_size := sb.push(sb.node_constant(sb.type_int(64), i32(len(msg_str)))) or_return

	msg := sb.push(sb.node_local(u32(len(msg_str) + 1), 0, 0)) or_return

	world := sb.Node_Edge {
		node = msg,
	}
	for i in 0 ..< len(msg_str) {
		data := sb.push(sb.node_constant(sb.type_int(8), i32(msg_str[i]))) or_return
		ptr := sb.push(sb.node_member_access({node = msg, output = 1}, u32(i)) or_return) or_return
		store := sb.push(sb.node_store(world, {node = ptr}, {node = data}) or_return) or_return
		world = {
			node = store,
		}
	}

	syscall := sb.push(
		sb.node_syscall(
			{start, 0},
			world,
			{node = one},
			{{node = one}, {node = msg, output = 1}, {node = msg_size}},
		) or_return,
	) or_return
	sb.end_function(fun, {{syscall, 0}}) or_return

	return .None
}

read_poisson :: proc() -> mem.Allocator_Error {
	fun := sb.start_function(
		{},
		{sb.type_int(8)},
		{name = "_start", linkage = .External},
	) or_return

	local := sb.push(sb.node_local(1, 0, 0)) or_return
	byte := sb.push(sb.node_load({local, 0}, {local, 1}, sb.type_int(8)) or_return) or_return

	sb.end_function(fun, {{byte, 0}}) or_return

	return .None
}

main :: proc() {
	graph: sb.Backend
	graph.target.char_bits = 8
	graph.target.ptr_size = 8
	graph.target.syscall_result = sb.type_int(64)
	context.user_ptr = &graph

	// main_err()
	read_poisson()

	buf := strings.builder_make_none()
	sb.sbprint_graph(&buf)
	fmt.println(strings.to_string(buf))

	opt.perform_pass(opt.pass_unalias_memory)
	opt.perform_pass(opt.pass_poison_read)
	opt.perform_remove_dead()

	buf2 := strings.builder_make_none()
	sb.sbprint_graph(&buf2)
	fmt.println(strings.to_string(buf2))
}
