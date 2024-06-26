# Script to test convective transport of temperature
# Observing transport of temperature pulse along pipes
# Following Section 4.1: Case 1, Hirsch and Nicolai, 
# "An efficient numerical solution method for detailed modelling of large 5th generation
# district heating and cooling networks", 2022.


import NetworkDynamics as nd
import DifferentialEquations as de
import Graphs as gr
import LinearAlgebra as la
import Plots as plt

import HDF5

include("../../src/DHG.jl")
import .DHG.Discretisation


# --- Parameters ---

write_hdf5 = true # Whether to write results to hdf5
plot_results = false # Whether to plot results

export_filename = "convection.h5"
writemode = "cw" # https://juliaio.github.io/HDF5.jl/stable/#Creating-a-group-or-dataset


massflow = 0.3 # [kg/s], value from Hirsch and Nicolai
density = 1e3 # [kg/m^3]
fixed_temperature = 20 + 273.15 # [K], value from Hirsch and Nicolai
initial_temperature = 10 + 273.15

pipe_diameter = 40.8e-3 # [m], value from Hirsch and Nicolai
pipe_length = 100.0 # [m], value from Hirsch and Nicolai

dxs = [1.0 / 2^r for r in 0:2]
schemes = [Discretisation.FVM(dx=dx, convection=DHG.Discretisation.upwind) for dx in dxs]
scheme_name = "Upwind"
max_CFL = 1.0 # set to nothing to disable constraint

timespan = (0.0, 20 * 60.0) # [s]
saveinterval = 1.0 # [s]


# --- end of parameters ---

# Dynamical functions for NetworkDynamics.jl

function src_node(dv, v, edges_in, edges_out, p, _)
    if p.massflow >= 0
        dv[1] = v[1] - p.fixed_temp
    else
        dv[1] = v[1] - edges_out[1][2]
    end
    return nothing
end

function dst_node(dv, v, edges_in, _, p, _)
    if p.massflow >= 0
        dv[1] = v[1] - edges_in[1][end]
    else
        dv[1] = v[1] - p.fixed_temp
    end
    return nothing
end

function pipe(de, e, v_s, v_d, p, _)
    dx = p.grid_sizing
    disc_scheme = p.discretisation
    massflow = p.massflow

    velocity = massflow / (p.density * 0.25 * pi * p.diameter^2)
    @views convection = -(1 / dx) .* disc_scheme.convection(e[2:end], v_s[1], v_d[1], velocity)

    de[1] = e[1] - massflow # enforce mass flow rate
    de[2:end] .= convection

    return nothing
end


# Function to test multiple combinations of (scheme, grid sizing)
function test_discretisation(discretisation_scheme::Discretisation.DiscretisationScheme,
                            grid_sizing::Float64,
                            max_timestep::Float64
                            )                            

    # Set up problem and solve
    parameters = (fixed_temp = fixed_temperature,
                  grid_sizing = grid_sizing,
                  discretisation = discretisation_scheme,
                  massflow = massflow,
                  density = density,
                  diameter = pipe_diameter,
                 )

    # Graph
    g = gr.SimpleDiGraph(2)
    gr.add_edge!(g, 1, 2) ? nothing : throw("Graphs.add_edge!() unsuccessful")


    # ODEEdge arguments
    n_edgedims::Int = div(pipe_length, grid_sizing, RoundNearest) + 1

    M_edge = [1 for _ in 1:n_edgedims]
    M_edge[1] = 0 # state 1 is an algebraic constraint

    syms_edge = [Symbol("T_$i") for i in 0:(n_edgedims-1)]
    syms_edge[1] = :m
    syms_edge[end] = :T_end

    src_node_fn = nd.DirectedODEVertex(f=src_node, dim=1, mass_matrix=la.Diagonal([0]), sym=[:T_src])
    dst_node_fn = nd.DirectedODEVertex(f=dst_node, dim=1, mass_matrix=la.Diagonal([0]), sym=[:T_dst])
    edge_fn = nd.ODEEdge(f=pipe, dim=n_edgedims, coupling=:directed, mass_matrix=la.Diagonal(M_edge),
                         sym=syms_edge)

    nd_fn = nd.network_dynamics([src_node_fn, dst_node_fn], [edge_fn], g)

    # Initialise state vector: massflow states must be nonzero, required for node temperature calculation
    n_states = length(nd_fn.syms)
    initial_guess = [initial_temperature for _ in 1:n_states]
    initial_guess[nd.idx_containing(nd_fn, :m_edge)] .= rand(Float64)


    prob = de.ODEProblem(nd_fn, initial_guess, timespan, parameters)
    if max_timestep > 0.0
        sol = de.solve(prob, de.Rodas5(), saveat=saveinterval, dtmax=max_timestep)
    else
        sol = de.solve(prob, de.Rodas5(), saveat=saveinterval)
    end

    if sol.retcode !== de.ReturnCode.Success
        throw("Unsuccessful retcode from solver")
    end

    println("Done: dx = $grid_sizing")

    return (times = sol.t,
            T_src = [u[nd.idx_containing(nd_fn, "T_src")][1] for u in sol.u],
            T_dst = [u[nd.idx_containing(nd_fn, "T_dst")][1] for u in sol.u]
           )
end


# Test (scheme, grid_sizing)

expected_velocity = massflow / (density * 0.25 * pi * pipe_diameter^2)
expected_time = pipe_length / abs(expected_velocity) # Time for temperature of src node to reach dst node

if max_CFL !== nothing
    max_dts = abs.([max_CFL * dx / expected_velocity for dx in dxs]) # CFL = u * dt / dx
else
    max_dts = [-1.0 for _ in dxs]
end


sols = [test_discretisation(scheme, dx, max_dt)
        for (scheme, dx, max_dt) in zip(schemes, dxs, max_dts)
       ]

for (i, sol) in enumerate(sols)
    times = sol.times
    if massflow >= 0
        T_dst = sol.T_dst
        plt.plot!(times, T_dst, label="T_dst, dx: $(dxs[i])")
    else
        T_src = sol.T_src
        plt.plot!(times, T_src, label="T_src, dx: $(dxs[i])")
    end
end

if plot_results
    p = plt.vline!([expected_time], label="", line=(:dot, "black", 2))
    plt.xlabel!("Time (s)")
    plt.ylabel!("Temperature (K)")
    plt.title!("Comparison of mesh sizings: $scheme_name interpolation, massflow: $massflow", titlefontsize=8)
    display(p)
end

if write_hdf5
    print("Exporting results ... ")
    HDF5.h5open(export_filename, writemode) do fid
        HDF5.create_group(fid, scheme_name)
        for (i, _) in enumerate(schemes)
            g = HDF5.create_group(fid[scheme_name], "discn$i")
            data = Dict("dx" => dxs[i], "times" => sols[i].times,
                        "T_src" => sols[i].T_src, "T_dst" => sols[i].T_dst
                       )
            for (key, value) in data
                g[key] = value
            end
        end
    end
    println("done")
end
