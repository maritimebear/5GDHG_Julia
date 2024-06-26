# Script to compare steady-state solution for various discretisation schemes and grid sizings
#
# References:
#
# Hirsch and Nicolai, "An efficient numerical solution method for detailed modelling of large
#   5th generation district heating and cooling networks", 2022, Section 4.1, Case 1
#
# Licklederer et al, "Thermohydraulic model of Smart Thermal Grids with bidirectional power flow
#   between prosumers", 2021
#
# Rocha et al, "Internal surface roughness of plastic pipes for irrigation", 2017
#
# Dang et al, "Fifth generation district heating and cooling: A comprehensive survey", 2024


import SciMLNLSolve
import Random

import HDF5
import GLMakie as mk

include("../../src/DHG.jl")
import .DHG

include("./utils_discncomparison.jl")
import .utils

# --- Parameters ---- #

Random.seed!(93851203598)

export_results = true # Export results to HDF5
export_filename = "gridconvergence_hirsch.h5"
writemode = "cw" # https://juliaio.github.io/HDF5.jl/stable/#Creating-a-group-or-dataset

plot_results = false

solver = SciMLNLSolve.NLSolveJL
initial_dx = 20.0 # [m]
refinement_ratio = 2
n_refinement_levels = 5


## Fixed/reference values
n_nodes = 4
init_massflows = rand(Float64, (n_nodes, )) # Initial values for massflow states
T_ambient = 273.15 + 5.0 # [K], Hirsch
p_ref = 0.0 # [Pa], reference pressure


## Pipe geometry, same for all pipes
# Values from Hirsch and Nicolai:
pipe_innerdiameter = 40.8e-3 # [m]
pipe_outerdiameter = 50e-3 # [m]
pipe_length = 100.0 # [m]
wall_conductivity = 0.4 # [W/m-K]


## Prosumers: massflow, thermal power
massflow = 0.3 # [kg/s], Hirsch and Nicolai
consumer_heatrate = -2.7e3 # [W] Assuming temperature change across consumer = -4 K [Hirsch]


## Pump model for producer
# Values from Licklederer et al:
pump_nominalspeed = 4100.0 # rpm
pump_ref1 = (0.0, 40221.0, pump_nominalspeed) # (massflow [kg/s], deltaP [Pa], speed [rpm])
pump_ref2 = (0.922, 0.0, pump_nominalspeed)


## Material properties, taking propylene glycol (Propane-1,3-diol) as fluid [Hirsch]
density = 1064.4 # [kg/m^3], value at 0°C, VDI Heat Atlas D3.1. Table 2 (pg 315)
fluid_T = DHG.Fluids.PropyleneGlycol


## Properties of pipe wall, polyethylene pipe [Hirsch]
wall_roughness = 8.116e-6 # [m], Rocha


## Discretisation
dxs = [initial_dx / (refinement_ratio ^ r) for r in 0:n_refinement_levels]

convection_schemes = Dict("Upwind" => DHG.Discretisation.upwind,
                          "Linear Upwind" => DHG.Discretisation.linear_upwind,
                          "van Leer" => DHG.Discretisation.vanLeer,
                          "van Albada" => DHG.Discretisation.vanAlbada,
                          "MINMOD" => DHG.Discretisation.minmod,
                         )


## Transport properties
transport_models = DHG.TransportModels(friction_factor=DHG.Transport.friction_Churchill,
                                       Nusselt_number=DHG.Transport.Nusselt_ChiltonColburn)


## Prosumer functions
consumer_hydctrl = (t) -> (massflow)
consumer_hydchar = (ctrl_input, massflow) -> (ctrl_input) # Return control input unchanged
consumer_thmctrl = (t) -> (consumer_heatrate)

producer_hydctrl = (t) -> (pump_nominalspeed)
producer_hydchar = DHG.Miscellaneous.PumpModel(pump_ref1..., pump_ref2..., density, pump_nominalspeed)
producer_thmctrl = (t) -> (-1.05 * consumer_thmctrl(t)) # Assuming heat loss in pipes = 5 to 20% of transmitted energy [Dang]


## Network structure
node_structs = (DHG.JunctionNode(),
                DHG.JunctionNode(),
                DHG.JunctionNode(),
                DHG.ReferenceNode(p_ref),
               ) # Using tuples instead of Vectors: types are not uniform, network structure is constexpr

edge_structs = (
                DHG.Pipe(1, 3, # src, dst
                         pipe_innerdiameter, pipe_outerdiameter, pipe_length,
                         wall_roughness, wall_conductivity), # hot pipe
                DHG.PressureChange(2, 1,
                                   producer_hydctrl, producer_thmctrl, producer_hydchar), # producer
                DHG.Massflow(3, 4,
                             consumer_hydctrl, consumer_thmctrl, consumer_hydchar), # consumer
                DHG.Pipe(4, 2,
                         pipe_innerdiameter, pipe_outerdiameter, pipe_length,
                         wall_roughness, wall_conductivity), # cold pipe
               )

# --- end of parameters --- #


params = (density=density, T_ambient=T_ambient)

result_tuple_T = NamedTuple{(:syms, :sol),
                            Tuple{Vector{Symbol}, Vector{Float64}}
                           } # DataType: (syms=symbols vector, sol=solution vector)

results = Dict{String,                      # convection scheme name
               Vector{result_tuple_T}       # dx index => result
              }() # Using Vector and not Dict(dx => result) to not use Floats as keys

# Compare discretisation schemes
for (name, scheme) in convection_schemes

    println("Convection scheme: $name")
    results[name] = Vector{result_tuple_T}()

    for (idx_dx, dx) in enumerate(dxs)
        discretisation = DHG.Discretisation.FVM(dx=dx, convection=scheme)

        ## Set up problem
        nd_fn, g = DHG.assemble(node_structs, edge_structs, transport_models, discretisation, fluid_T)
            # nd_fn = NetworkDynamics.network_dynamics(collect(node_structs), collect(edge_structs), g)

        ## Initialise state vector: massflow states must be nonzero, required for node temperature calculation
        #   number of massflow and pressure states are constant; == n_nodes
        #   number of temperature states depends on dx
        initial_guess = DHG.Miscellaneous.initialise(nd_fn,
                                                     (_) -> init_massflows, # massflows to init_massflow
                                                     p_ref,                 # pressures to p_ref
                                                     T_ambient              # temperatures to T_ambient
                                                    )

        ## Solve for steady-state
        print("Starting solve: dx = $dx")
        push!(results[name],
              (syms=nd_fn.syms, sol=DHG.Miscellaneous.solve_steadystate(nd_fn, initial_guess, params, solver()))
             )
        println(" --- done")
    end
end


# Post-processing

node_Ts = [utils.get_states(DHG.PostProcessing.node_T_idxs, results, node_idx) |>
           dict -> Dict(k => [v[1] for v in vs] for (k, vs) in dict) # Unpack 1-element Vector{Float64}
           for (node_idx, _) in enumerate(node_structs)
          ] # Temperature at each node across discn. schemes and dxs


## Grid Convergence -- relative errors, order of convergence, GCI

node_errors = [Dict(scheme => [utils.relative_error(Ts_at_dx[i+1], Ts_at_dx[i]) # relative_error(finer, coarser)
                                for (i, _) in enumerate(Ts_at_dx[1:end-1])
                              ]
                    for (scheme, Ts_at_dx) in Ts_dict
                   )
                for Ts_dict in node_Ts
              ] # Relative error at each node across discn. schemes and (coarser dx, finer dx)

results_postprocessed = [Dict(scheme_name => (order_convergence=Vector{Float64}(), gci=Vector{Float64}())
                              for (scheme_name, _) in convection_schemes)
                         for _ in enumerate(node_structs)
                        ]

println("\n\nGrid convergence report")
println("-------------------------\n")
println("Grid base size: $initial_dx\n\n")

for (node_idx, _) in enumerate(node_Ts)
    println("Node $node_idx:\n")
    Ts_dict = node_Ts[node_idx]
    errors_dict = node_errors[node_idx]
    for (scheme, _) in Ts_dict
        println("Scheme: $scheme\n")
        for i in 1:3:(3 * div(length(dxs), 3, RoundDown)) # Order of convergence works on sets of 3 dxs
            println("Refinement levels: $(collect(i-1:i+1))")
            println("Grid sizes: $(dxs[i:i+2])")
            p = utils.order_convergence(Ts_dict[scheme][i:i+2], refinement_ratio)
            GCIs = [utils.GCI_fine(errors_dict[scheme][i], refinement_ratio, p),
                    utils.GCI_fine(errors_dict[scheme][i+1], refinement_ratio, p)
                   ]
            println("Order of convergence: $p")
            @show GCIs
            println("\nAsymptotic convergence check: \
                    (GCI ratio / r^p) = $(GCIs[1] / (GCIs[2] * refinement_ratio^p))\n")
            # Save post-processed results
            push!(results_postprocessed[node_idx][scheme].order_convergence, p)
            push!(results_postprocessed[node_idx][scheme].gci, GCIs...)
        end
        println("\n")
    end
end

## Export results
if export_results
    print("Exporting results ... ")
    HDF5.h5open(export_filename, writemode) do fid
        for (scheme_name, _) in convection_schemes
            g = HDF5.create_group(fid, scheme_name)
            g["dxs"] = dxs
            g["nodes_temperatures"] = [node_Ts[node_idx][scheme_name][dx_idx]
                                       for (node_idx, _) in enumerate(node_structs),
                                       (dx_idx, _) in enumerate(dxs)
                                      ] # columns => nodes, rows => dxs, loop orders reversed: HDF5 expects row-major

            g["nodes_errors"] = [node_errors[node_idx][scheme_name][ref_idx]
                                 for (node_idx, _) in enumerate(node_structs),
                                 ref_idx in 1:n_refinement_levels
                                ] # columns => nodes, rows => refinement steps

            g["nodes_orderconvs"] = [results_postprocessed[node_idx][scheme_name].order_convergence[p_idx]
                                     for (node_idx, _) in enumerate(node_structs),
                                     p_idx in 1:div(length(dxs), 3, RoundDown)
                                    ] # columns => nodes, rows => sets of 3 grid sizes

            g["nodes_gcis"] = [results_postprocessed[node_idx][scheme_name].gci[gci_idx]
                               for (node_idx, _) in enumerate(node_structs),
                               gci_idx in 1:(div(length(dxs), 3, RoundDown) + 2)
                              ] # columns => nodes, rows => sets of 3 grid sizes
        end
    end
    println("done")
end

## Plots
if plot_results
    fig_nodeTs = mk.Figure()
    axes_nodeTs = [mk.Axis(fig_nodeTs[row, 1],
                           xticks = collect(0:n_refinement_levels),
                           xtickformat = xs -> ["1/$(2^Int(x))" for x in xs],
                           yticks=mk.LinearTicks(3),
                           # yminorticks=mk.IntervalsBetween(5), yminorticksvisible=true, yminorgridvisible=true,
                           # yticks = mk.MultiplesTicks(5, 1e-3, "a"),
                          ) for row in 1:4
                  ]

    lines_nodeTs = Dict(scheme_name => [mk.scatterlines!(axes_nodeTs[i],
                                                         0:n_refinement_levels, # x-axis
                                                         node_Ts[i][scheme_name], # y-axis
                                                         # node_errors[i][scheme_name],
                                                         linestyle=:dash, marker=:circle,
                                                        )
                                        for (i, _) in enumerate(node_structs)
                                       ]
                        for (scheme_name, _) in convection_schemes
                       )

    for (i, ax) in enumerate(axes_nodeTs)
        # Inset titles for axes
        mk.text!(ax,
                 1, 1, text="Node $i", font=:bold, #fontsize=11,
                 align=(:right, :top), space=:relative, offset=(-8, -4), justification=:right,
                )
    end
    display(fig_nodeTs)
end
