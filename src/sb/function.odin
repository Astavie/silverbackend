package sb

import "core:mem"
import "core:slice"

Function :: distinct u32
Function_Data :: struct {
	inputs:  []Data_Type,
	outputs: []Data_Type,
	start:   Node,
	end:     Node,
	symbol:  Symbol,
}

Linkage :: enum {
	Internal,
	External,
}

Symbol :: struct {
	name:    string,
	linkage: Linkage,
}

start_function :: proc(
	inputs: []Data_Type,
	outputs: []Data_Type,
	symbol: Symbol = {linkage = .Internal},
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	fun: Function,
	err: mem.Allocator_Error,
) #optional_allocator_error {
	sb := backend()
	fun = Function(len(sb.functions))

	inputs := slice.clone(inputs, allocator, loc)
	outputs := slice.clone(outputs, allocator, loc)

	start := Node(len(sb.nodes))
	append(&sb.nodes, node_start(fun)) or_return
	append(
		&sb.functions,
		Function_Data{inputs = inputs, outputs = outputs, start = start, symbol = symbol},
	) or_return

	return
}

end_function :: proc(
	fun: Function,
	outputs: []Node_Edge,
	allocator := context.allocator,
	loc := #caller_location,
) -> mem.Allocator_Error {
	sb := backend()

	node := push(node_end(fun, outputs, allocator, loc) or_return) or_return
	sb.functions[int(fun)].end = node

	return .None
}
