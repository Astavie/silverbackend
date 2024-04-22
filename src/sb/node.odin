package sb

import "base:intrinsics"
import "core:math/big"
import "core:mem"
import "core:slice"

@(private)
_log2_inc :: proc(x: u32) -> u32 {
	return size_of(u32) * 8 - intrinsics.count_leading_zeros(x)
}

@(private)
_log2_floor :: proc(x: u32) -> u32 {
	return _log2_inc(x) - 1
}

@(private)
_log2_ceil :: proc(x: u32) -> u32 {
	return _log2_inc(x - 1)
}

Node_Type :: enum u16 {
	// (...) -> (...) + varargs
	// a Node_Data with all 0 will be an empty Pass node
	Pass = 0,
	Poison, // () -> (data)

	// one START and END per function
	Start, // () -> (params...)
	End, // (ret...) -> ()

	// branching
	Branch, // (data, data...) -> (control)
	Phi, // (control, data/world...) -> (data/world)

	// memory
	Local, // () -> (world, pointer)
	Load, // (world, pointer) -> (data)
	Store, // (world, pointer, data) -> (world)
	Merge, // (world...) -> (world)
	Member_Access, // (pointer)          -> (pointer)
	Array_Access, // (pointer, integer) -> (pointer) 

	// constants
	Integer, // () -> (integer)

	// volatile
	Syscall, // (io, world, data, data...) -> (io, world, data)
	// Address, // (integer) -> (pointer)
	// Write,   // (io, pointer, data) -> (io)
	// Read,    // (io, pointer) -> (io, data)
}

Node :: distinct u32

Node_Data :: struct #raw_union {
	base:          struct {
		type: Node_Type,
	},
	pass:          struct {
		type:    Node_Type,
		_pad16:  u16,
		varargs: u32,
		inputs:  [^]Node_Edge,
	},
	poison:        struct {
		type:      Node_Type,
		data_type: Data_Type,
	},
	start:         struct {
		type:     Node_Type,
		_pad16:   u16,
		function: Function,
	},
	end:           struct {
		type:     Node_Type,
		_pad16:   u16,
		function: Function,
		inputs:   [^]Node_Edge,
	},
	branch:        struct {
		type:    Node_Type,
		_pad16:  u16,
		varargs: u32,
		inputs:  [^]Node_Edge,
	},
	phi:           struct {
		type:      Node_Type,
		data_type: Data_Type,
		varargs:   u32,
		inputs:    [^]Node_Edge,
	},
	local:         struct {
		type:     Node_Type,
		ptr_type: Data_Type,
		size:     u32,
	},
	load:          struct {
		type:      Node_Type,
		data_type: Data_Type,
		_pad32:    u32,
		inputs:    [^]Node_Edge,
	},
	store:         struct {
		type:   Node_Type,
		_pad16: u16,
		_pad32: u32,
		inputs: [^]Node_Edge,
	},
	merge:         struct {
		type:    Node_Type,
		_pad16:  u16,
		varargs: u32,
		inputs:  [^]Node_Edge,
	},
	member_access: struct {
		type:     Node_Type,
		ptr_type: Data_Type,
		offset:   u32,
		inputs:   [^]Node_Edge,
	},
	array_access:  struct {
		type:     Node_Type,
		ptr_type: Data_Type,
		size:     u32,
		inputs:   [^]Node_Edge,
	},
	integer:       struct {
		type:        Node_Type,
		int_type:    Data_Type,
		int_literal: i32,
		int_big:     ^big.Int,
	},
	syscall:       struct {
		type:    Node_Type,
		_pad16:  u16,
		varargs: u32,
		inputs:  [^]Node_Edge,
	},
}

Node_Edge :: struct {
	node:   Node,
	output: u32,
}

node_nil :: proc() -> Node_Data {
	return {}
}

node_poison :: proc(type: Data_Type) -> Node_Data {
	return {poison = {type = .Poison, data_type = type}}
}

node_start :: proc(fun: Function) -> Node_Data {
	return {start = {type = .Start, function = fun}}
}

node_end :: proc(
	fun: Function,
	inputs: []Node_Edge,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	Node_Data,
	mem.Allocator_Error,
) #optional_allocator_error {
	// TODO: check if edges match

	inputs, err := slice.clone(inputs, allocator, loc)
	return {end = {type = .End, function = fun, inputs = raw_data(inputs)}}, err
}

node_member_access :: proc(
	edge: Node_Edge,
	offset: u32,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	Node_Data,
	mem.Allocator_Error,
) #optional_allocator_error {
	ptrm := node_output_type(edge.node, edge.output)
	if ptr, ok := ptrm.?; ok {
		assert(ptr.base.type == .Pointer, "provided edge to member access is not ptr type")

		space := ptr.pointer.address_space
		align := ptr.pointer.align_exp
		if offset > 0 {
			align = min(align, u8(_log2_floor(offset)))
		}

		inputs, err := slice.clone([]Node_Edge{edge}, allocator, loc)
		return  {
				member_access =  {
					type = .Member_Access,
					ptr_type = type_ptr(align, space),
					offset = offset,
					inputs = raw_data(inputs),
				},
			},
			err
	} else {
		panic("provided edge to member access not connected to valid node output")
	}
}

node_load :: proc(
	world: Node_Edge,
	ptr: Node_Edge,
	type: Data_Type,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	Node_Data,
	mem.Allocator_Error,
) #optional_allocator_error {
	// TODO: check if edges match
	inputs, err := slice.clone([]Node_Edge{world, ptr}, allocator, loc)
	return {load = {type = .Load, data_type = type, inputs = raw_data(inputs)}}, err
}

node_store :: proc(
	world: Node_Edge,
	ptr: Node_Edge,
	data: Node_Edge,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	Node_Data,
	mem.Allocator_Error,
) #optional_allocator_error {
	// TODO: check if edges match

	inputs, err := slice.clone([]Node_Edge{world, ptr, data}, allocator, loc)
	return {store = {type = .Store, inputs = raw_data(inputs)}}, err
}

node_syscall :: proc(
	io: Node_Edge,
	world: Node_Edge,
	nr: Node_Edge,
	args: []Node_Edge,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	Node_Data,
	mem.Allocator_Error,
) #optional_allocator_error {
	// TODO: check if edges match

	inputs, err := mem.make_slice([]Node_Edge, len(args) + 3)
	if err != .None {
		return {}, err
	}

	inputs[0] = io
	inputs[1] = world
	inputs[2] = nr
	for i := 0; i < len(args); i += 1 {
		inputs[i + 3] = args[i]
	}

	return {syscall = {type = .Syscall, varargs = u32(len(args)), inputs = raw_data(inputs)}}, err
}

node_pass :: proc(heap_inputs: []Node_Edge) -> Node_Data {
	return {pass = {type = .Pass, varargs = u32(len(heap_inputs)), inputs = raw_data(heap_inputs)}}
}

node_merge :: proc(
	inputs: []Node_Edge,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	Node_Data,
	mem.Allocator_Error,
) #optional_allocator_error {
	// TODO: check if edges match

	inputs, err := slice.clone(inputs, allocator, loc)
	return {merge = {type = .Merge, varargs = u32(len(inputs)), inputs = raw_data(inputs)}}, err
}

node_local :: proc(sizeof: u32, align_exp: u8, address_space: u8) -> Node_Data {
	return {local = {type = .Local, ptr_type = type_ptr(align_exp, address_space), size = sizeof}}
}

node_constant_i32 :: proc(type: Data_Type, value: i32) -> Node_Data {
	assert(type.base.type == .Integer, "provided int constant to non-integer type")
	return {integer = {type = .Integer, int_type = type, int_literal = value, int_big = nil}}
}

node_constant_bigint :: proc(
	type: Data_Type,
	value: big.Int,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	Node_Data,
	mem.Allocator_Error,
) #optional_allocator_error {
	assert(type.base.type == .Integer, "provided int constant to non-integer type")

	value, err := mem.new_clone(value, allocator, loc)
	return {integer = {type = .Integer, int_type = type, int_big = value}}, err
}

node_constant :: proc {
	node_constant_i32,
	node_constant_bigint,
}

canonical_edge :: proc(n: Node_Edge) -> Node_Edge {
	current := n
	for node_type(current.node) == .Pass {
		current = node_inputs(current.node)[current.output]
	}
	return current
}

node_parent :: proc(node: Node, input: int) -> Node_Edge {
	return canonical_edge(node_inputs(node)[input])
}

node_destroy :: proc(node: Node_Data) {
	if node.base.type == .Integer && node.integer.int_big != nil {
		big.destroy(node.integer.int_big)
	}

	// We pretend the Node is of type Node_Type.End to get the 'inputs' field
	// This is safe, because Nodes without a pointer here will have it set to '0', the nil pointer
	// Freeing the nil pointer is safe
	free(transmute(rawptr)node.end.inputs)
}

node_type :: proc(node: Node) -> Node_Type {
	return backend().nodes[int(node)].base.type
}

node_data :: proc(node: Node) -> ^Node_Data {
	return &backend().nodes[int(node)]
}

node_inputs :: proc(node: Node) -> []Node_Edge {
	sb := backend()
	node := &sb.nodes[int(node)]

	count: u32
	switch node.base.type {
	case .Start:
		count = 0
	case .Poison:
		count = 0
	case .End:
		count = u32(len(sb.functions[int(node.end.function)].outputs))
	case .Branch:
		count = 1 + node.branch.varargs
	case .Phi:
		count = 1 + node.phi.varargs
	case .Local:
		count = 0
	case .Load:
		count = 2
	case .Store:
		count = 3
	case .Integer:
		count = 0
	case .Merge:
		count = node.merge.varargs
	case .Syscall:
		count = 3 + node.syscall.varargs
	case .Pass:
		count = node.pass.varargs
	case .Member_Access:
		count = 1
	case .Array_Access:
		count = 2
	}

	// We pretend the Node is of type Node_Type.End to get the 'inputs' field
	return mem.slice_ptr(node.end.inputs, int(count))
}

node_outputs :: proc(
	node: Node,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	[]Node_Edge,
	mem.Allocator_Error,
) #optional_allocator_error {
	size := 0
	for node_output_type(node, u32(size)) != nil {
		size += 1
	}

	outputs, err := mem.make_slice([]Node_Edge, size, allocator, loc)
	if err != .None do return nil, err

	for i in 0 ..< size {
		outputs[i] = {node, u32(i)}
	}
	return outputs, .None
}

node_output_type :: proc(node: Node, idx: u32) -> Maybe(Data_Type) {
	inputs := node_inputs(node)

	graph := backend()
	node := &graph.nodes[int(node)]

	switch node.base.type {
	case .Start:
		inputs := graph.functions[int(node.start.function)].inputs
		if int(idx) < len(inputs) {
			return inputs[int(idx)]
		}
	case .Poison:
		if idx == 0 {
			return node.poison.data_type
		}
	case .End:
	case .Branch:
		if idx == 0 {
			return type_control()
		}
	case .Phi:
		if idx == 0 {
			return node.phi.data_type
		}
	case .Local:
		if idx == 0 {
			return type_memory()
		}
		if idx == 1 {
			return node.local.ptr_type
		}
	case .Load:
		if idx == 0 {
			return node.load.data_type
		}
	case .Store:
		if idx == 0 {
			return type_memory()
		}
	case .Merge:
		if idx == 0 {
			return type_memory()
		}
	case .Integer:
		if idx == 0 {
			return node.integer.int_type
		}
	case .Syscall:
		if idx == 0 {
			return type_io()
		}
		if idx == 1 {
			return type_memory()
		}
		if idx == 2 {
			return graph.target.syscall_result
		}
	case .Pass:
		if int(idx) < len(inputs) {
			return node_output_type(inputs[int(idx)].node, inputs[int(idx)].output)
		}
	case .Member_Access:
		if idx == 0 {
			return node.member_access.ptr_type
		}
	case .Array_Access:
		if idx == 0 {
			return node.array_access.ptr_type
		}
	}

	return nil
}
