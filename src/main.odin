package silverbackend

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

import sb "graph"
import opt "optimization"

main_err :: proc() -> mem.Allocator_Error {
	g := sb.graph()

	fun := sb.start_function(
		{sb.type_io()},
		{sb.type_io()},
		{name = "_start", linkage = .External},
	) or_return
	start := g.functions[int(fun)].start

	msg_str := transmute([]u8)string("Hello, World!\n\x00")

	one := sb.push(sb.node_constant(sb.type_int(64), 1)) or_return
	msg_size := sb.push(sb.node_constant(sb.type_int(64), i32(len(msg_str)))) or_return

	msg := sb.push(sb.node_local(u32(len(msg_str)), 3, 0)) or_return

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
	g: sb.Graph
	g.target.char_bits = 8
	g.target.ptr_size = 8
	g.target.syscall_result = sb.type_int(64)
	g.target.endian = .Little
	context.user_ptr = &g

	main_err()
	// read_poisson()

	buf := strings.builder_make_none()
	sb.sbprint_graph(&buf)
	fmt.println(strings.to_string(buf))

	// change in series store operations to be parallel where order doesn't matter,
	// with a Memory Merge node at the end
	opt.perform_pass(opt.pass_unalias_memory)

	// change a Load node into a Poison node if loading from unitialized memory
	opt.perform_pass(opt.pass_poison_read)

	// merge parallel stores together into one store if the memory is consecutive
	opt.perform_pass(opt.pass_merge_stores)

	// remove inputs from a Memory Merge node if it merges the same memory outputs,
	// may also completely remove the Memory Merge node
	opt.perform_pass(opt.pass_optimize_merge)

	// go through and remove unused nodes
	opt.perform_remove_dead()

	buf2 := strings.builder_make_none()
	sb.sbprint_graph(&buf2)
	fmt.println(strings.to_string(buf2))

	// get node order
	slice := sb.function_graph_order(0)
	for node in slice {
		fmt.println(node, sb.node_type(node))
	}
}
