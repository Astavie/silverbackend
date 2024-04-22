package sb

import "core:fmt"
import "core:mem"
import "core:strings"

Graph :: struct {
	nodes:     [dynamic]Node_Data,
	functions: [dynamic]Function_Data,
	target:    Target,
}

Target :: struct {
	syscall_result: Data_Type,
	ptr_size:       u16,
	char_bits:      u16,
}

graph :: proc() -> ^Graph {
	return transmute(^Graph)context.user_ptr
}

push :: proc(node_data: Node_Data) -> (Node, mem.Allocator_Error) #optional_allocator_error {
	g := graph()
	_, err := append(&g.nodes, node_data)
	return Node(len(g.nodes) - 1), err
}

sbprint_graph :: proc(buf: ^strings.Builder) {
	g := graph()

	fmt.sbprintln(buf, "digraph {")
	fmt.sbprintln(buf, "graph [rankdir = \"LR\"]")
	for i in 0 ..< len(g.nodes) {
		node := g.nodes[i]

		#partial switch node.base.type {
		case .Pass:
			continue
		case .Integer:
			// TODO: check if big int
			fmt.sbprintf(buf, "%d [label = \"%d\"]\n", i, node.integer.int_literal)
		case:
			fmt.sbprintf(buf, "%d [shape = \"record\", label = \"", i)

			#partial switch node.base.type {
			case .Member_Access:
				fmt.sbprintf(buf, "offset %d", node.member_access.offset)
			case:
				fmt.sbprint(buf, node.base.type)
			}

			fmt.sbprint(buf, "|{{")
			for edge, i in node_inputs(Node(i)) {
				fmt.sbprintf(buf, "<i%d>", i)
				tym := node_output_type(edge.node, edge.output)
				if ty, ok := tym.?; ok {
					type_name(buf, ty)
				}
				fmt.sbprint(buf, "|")
			}
			if len(node_inputs(Node(i))) > 0 do strings.pop_byte(buf)

			fmt.sbprint(buf, "}|{")
			for o in 0 ..= 99999 {
				tym := node_output_type(Node(i), u32(o))
				if ty, ok := tym.?; ok {
					fmt.sbprintf(buf, "<o%d>", o)
					type_name(buf, ty)
					fmt.sbprint(buf, "|")
				} else {
					if o > 0 do strings.pop_byte(buf)
					break
				}
			}
			fmt.sbprint(buf, "}}|")

			fmt.sbprintln(buf, "\"]")
		}
	}
	for n in 0 ..< len(g.nodes) {
		#partial switch node_type(Node(n)) {
		case .Pass:
			continue
		}
		for edge_pass, i in node_inputs(Node(n)) {
			edge := canonical_edge(edge_pass)
			fmt.sbprintf(buf, "%d:o%d -> %d:i%d\n", edge.node, edge.output, n, i)
		}
	}
	fmt.sbprintln(buf, "}")
}
