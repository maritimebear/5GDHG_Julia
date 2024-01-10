module DHG

include("./Utilities.jl")               # submodule Utilities
include("./FVM.jl")                     # provides submodule FVM
include("./NetworkComponents.jl")       # submodule NetworkComponents
include("./TransportProperties.jl")     # submodule TransportProperties
include("./DynamicalFunctions.jl")      # submodule DynamicalFunctions
include("./WrapperFunctions.jl")        # submodule WrapperFunctions
include("./GraphParsing.jl")            # submodule GraphParsing
include("./ParameterStructs.jl")        # submodule ParameterStructs

# TODO: export parse_gml, others?
# TODO: global size_t, but NetworkDynamics takes dims::Int

import Graphs: SimpleGraphs.SimpleDiGraph
import NetworkDynamics
import DifferentialEquations: SciMLBase

# import and re-export from submodules for easier access
import .GraphParsing: parse_gml
import .ParameterStructs: GlobalParameters
import .TransportProperties: TransportCoefficients

export GlobalParameters, TransportProperties, parse_gml

export DHGStruct


Base.@kwdef struct DHGStruct{FunctionType <: SciMLBase.AbstractODEFunction, IndexType <: Integer}
    # node_functions::Vector{NetworkDynamics.DirectedODEVertex}
    # edge_functions::Vector{NetworkDynamics.ODEEdge}
    f::FunctionType
    parameters::ParameterStructs.Parameters
    graph::SimpleDiGraph{IndexType}
    edges::Vector{NetworkComponents.Edge}
    n_states::NamedTuple{(:nodes, :edges),
                         Tuple{Vector{UInt16}, Vector{UInt16}} # Determines max number of states, change in constructor as well if modified
                        }
end


function DHGStruct(graph_parser::Function,
                    global_parameters::ParameterStructs.GlobalParameters,
                    transport_coeffs::TransportProperties.TransportCoefficients,
                )
    # Constructor

    graph, node_dict, edge_dict = graph_parser()
    edgevec::Vector{NetworkComponents.Edge} = edge_dict.components
    parameters = ParameterStructs.Parameters(global_parameters = global_parameters,
                                             node_parameters = ParameterStructs.NodeParameters(node_dict),
                                             edge_parameters = ParameterStructs.EdgeParameters(edge_dict)
                                            )
    # Assemble dynamical functions
    node_fns = Vector{NetworkDynamics.DirectedODEVertex}(undef, length(node_dict.components))
    edge_fns = Vector{NetworkDynamics.ODEEdge}(undef, length(edgevec))
    n_states = (nodes=similar(node_fns, UInt16), edges=similar(edge_fns, UInt16))

    for (i, node) in enumerate(node_dict.components)
        node_fns[i] = WrapperFunctions.node_fn(node)
        n_states.nodes[i] = node_fns[i].dim
    end

    for (i, edge) in enumerate(edgevec)
        edge_fns[i] = WrapperFunctions.edge_fn(i, edge, transport_coeffs)
        n_states.edges[i] = edge_fns[i].dim
    end

    ode_fn = NetworkDynamics.network_dynamics(node_fns, edge_fns, graph)

    return DHGStruct(f=ode_fn, parameters=parameters, graph=graph, edges=edgevec, n_states=n_states)
end

end # module DHG
