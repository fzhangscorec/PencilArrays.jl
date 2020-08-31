#!/usr/bin/env julia

using PencilArrays
using PencilArrays.Permutations

const PA = PencilArrays

using MPI

using BenchmarkTools
using LinearAlgebra: transpose!
using Random
using Test

include("include/MPITools.jl")
using .MPITools

const BENCHMARK_ARRAYS = "--benchmark" in ARGS
BenchmarkTools.DEFAULT_PARAMETERS.seconds = 1.0

Indexation(::Type{IndexLinear}) = LinearIndices
Indexation(::Type{IndexCartesian}) = CartesianIndices

function test_fill!(::Type{T}, u, val) where {T <: IndexStyle}
    for I in Indexation(T)(u)
        @inbounds u[I] = val
    end
    u
end

function test_array_wrappers(p::Pencil, ::Type{T} = Float64) where {T}
    u = PencilArray{T}(undef, p)
    perm = get_permutation(p)

    @test eltype(u) === eltype(u.data) === T
    @test length.(axes(u)) === size(u)

    randn!(u)
    @test check_iteration_order(u)

    if BENCHMARK_ARRAYS
        for S in (IndexLinear, IndexCartesian)
            @info("Filling arrays using $S (Array, PencilArray)",
                  get_permutation(p))
            for v in (parent(u), u)
                val = 3 * oneunit(eltype(v))
                @btime test_fill!($S, $v, $val)
            end
            println()
        end
    end

    let v = similar(u)
        @test typeof(v) === typeof(u)

        psize = size_local(p, permute=false)
        @test psize === size(v) === size(u)
        @test psize ===
            size_local(u, permute=false) === size_local(v, permute=false)

        vp = parent(v)
        randn!(vp)
        I = size(v) .>> 1  # non-permuted indices
        J = PA.permute_indices(I, perm)
        @test v[I...] == vp[J...]  # the parent takes permuted indices
    end

    let psize = size_local(p, permute=true)
        a = zeros(T, psize)
        u = PencilArray(p, a)
        @test u.data === a
        @test IndexStyle(typeof(u)) === IndexStyle(typeof(a)) === IndexLinear()

        b = zeros(T, psize .+ 2)
        @test_throws DimensionMismatch PencilArray(p, b)
        @test_throws DimensionMismatch PencilArray(p, zeros(T, 3, psize...))

        # This is allowed.
        w = PencilArray(p, zeros(T, psize..., 3))
        @test size_global(w) === (size_global(p)..., 3)

        @inferred PencilArray(p, zeros(T, psize..., 3))
        @inferred size_global(w)
    end

    nothing
end

function test_multiarrays(pencils::Vararg{Pencil,M};
                          element_type::Type{T} = Float64) where {M,T}
    @assert M >= 3
    @inferred ManyPencilArray{T}(undef, pencils...)

    A = ManyPencilArray{T}(undef, pencils...)

    @test ndims(A) === ndims(first(pencils))
    @test eltype(A) === T
    @test length(A) === M

    @inferred first(A)
    @inferred last(A)
    @inferred A[Val(2)]
    @inferred A[Val(M)]

    @test_throws ErrorException @inferred A[2]  # type not inferred

    @test A[Val(1)] === first(A) === A[Val(UInt8(1))] === A[1]
    @test A[Val(2)] === A[2] === A.arrays[2] === A[Val(Int32(2))]
    @test A[Val(M)] === last(A)

    @test_throws BoundsError A[Val(0)]
    @test_throws BoundsError A[Val(M + 1)]

    @testset "In-place extra dimensions" begin
        e = (3, 2)
        @inferred ManyPencilArray{T}(undef, pencils...; extra_dims=e)
        A = ManyPencilArray{T}(undef, pencils...; extra_dims=e)
        @test extra_dims(first(A)) === extra_dims(last(A)) === e
        @test ndims_extra(first(A)) == ndims_extra(last(A)) == length(e)
    end

    @testset "In-place transpose" begin
        u = A[Val(1)]
        v = A[Val(2)]
        w = A[Val(3)]

        randn!(u)
        u_orig = copy(u)

        transpose!(v, u)  # this also modifies `u`!
        @test compare_distributed_arrays(u_orig, v)

        # In the 1D decomposition case, this is a local transpose, since v and w
        # only differ in the permutation.
        transpose!(w, v)
        @test compare_distributed_arrays(u_orig, w)
    end

    nothing
end

function check_iteration_order(u::PencilArray)
    p = parent(u)
    cart = CartesianIndices(u)
    lin = LinearIndices(u)

    # Check that Cartesian indices iterate in memory order.
    for (n, I) in enumerate(cart)
        l = lin[I]
        @assert l == n
        u[n] == p[n] == u[I] == u[l] || return false
    end

    # Also test iteration on LinearIndices and their conversion to Cartesian
    # indices.
    for (n, l) in enumerate(lin)
        @assert l == n
        # Convert linear to Cartesian index.
        I = cart[l]  # this is relatively slow, don't do it in real code!
        u[n] == p[n] == u[I] == u[l] || return false
    end

    true
end

function compare_distributed_arrays(u_local::PencilArray, v_local::PencilArray)
    comm = get_comm(u_local)
    root = 0
    myrank = MPI.Comm_rank(comm)

    u = gather(u_local, root)
    v = gather(v_local, root)

    same = Ref(false)
    if u !== nothing && v !== nothing
        @assert myrank == root
        same[] = u == v
    end
    MPI.Bcast!(same, length(same), root, comm)

    same[]
end

function main()
    MPI.Init()

    Nxyz = (16, 21, 41)
    comm = MPI.COMM_WORLD
    Nproc = MPI.Comm_size(comm)
    myrank = MPI.Comm_rank(comm)

    silence_stdout(comm)

    rng = MersenneTwister(42 + myrank)

    # Let MPI_Dims_create choose the values of (P1, P2).
    proc_dims = let pdims = zeros(Int, 2)
        MPI.Dims_create!(Nproc, pdims)
        pdims[1], pdims[2]
    end

    topo = MPITopology(comm, proc_dims)

    pen1 = Pencil(topo, Nxyz, (2, 3))
    pen2 = Pencil(pen1, decomp_dims=(1, 3), permute=Permutation(2, 3, 1))
    pen3 = Pencil(pen2, decomp_dims=(1, 2), permute=Permutation(3, 2, 1))

    println("Pencil 1: ", pen1, "\n")
    println("Pencil 2: ", pen2, "\n")
    println("Pencil 3: ", pen3, "\n")

    @testset "ManyPencilArray" begin
        test_multiarrays(pen1, pen2, pen3)
    end

    # Note: the permutation of pen2 was chosen such that the inverse permutation
    # is different.
    @assert pen2.perm !== PA.inverse_permutation(pen2.perm)

    @testset "Pencil constructor checks" begin
        # Too many decomposed directions
        @test_throws ArgumentError Pencil(
            MPITopology(comm, (Nproc, 1, 1)), Nxyz, (1, 2, 3))

        # Invalid permutations
        @test_throws TypeError Pencil(
            topo, Nxyz, (1, 2), permute=(2, 3, 1))
        @test_throws ArgumentError Pencil(
            topo, Nxyz, (1, 2), permute=Permutation(0, 3, 15))

        # Decomposed dimensions may not be repeated.
        @test_throws ArgumentError Pencil(topo, Nxyz, (2, 2))

        # Decomposed dimensions must be in 1:N = 1:3.
        @test_throws ArgumentError Pencil(topo, Nxyz, (1, 4))
        @test_throws ArgumentError Pencil(topo, Nxyz, (0, 2))

        @test Pencils.complete_dims(Val(5), (2, 3), (42, 12)) ===
            (1, 42, 12, 1, 1)
    end

    @testset "PencilArray" begin
        test_array_wrappers(pen1)
        test_array_wrappers(pen3)
    end

    @testset "permutations" begin
        @test get_permutation(pen1) === NoPermutation()
        @test get_permutation(pen2) === Permutation(2, 3, 1)

        @test PA.is_identity_permutation(NoPermutation())
        @test PA.is_identity_permutation(Permutation(1, 2, 3, 4))
        @test !PA.is_identity_permutation(Permutation(2, 1, 3, 4))

        @test Permutation(2, 3, 1) == Permutation(2, 3, 1)
        @test Permutation(2, 3, 1) != Permutation(2, 3, 1, 4)
        @test Permutation(2, 3, 1) != Permutation(2, 1, 3)
        @test NoPermutation() == NoPermutation()
        @test NoPermutation() == Permutation(1, 2, 3)
        @test NoPermutation() != Permutation(3, 2, 1)
        @test Permutation(1, 2, 3) == NoPermutation()
        @test Permutation(1, 3, 2) != NoPermutation()

        @test PA.relative_permutation(pen2, pen3) === Permutation(2, 1, 3)
        @test PA.relative_permutation(NoPermutation(),
                                      NoPermutation()) === NoPermutation()

        let a = Permutation((2, 1, 3)), b = Permutation((3, 2, 1))
            @test Tuple(a) === (2, 1, 3)
            @test_throws ErrorException Tuple(NoPermutation())

            @test PA.permute_indices((:a, :b, :c), Permutation((2, 3, 1))) ===
                (:b, :c, :a)
            a2b = PA.relative_permutation(a, b)
            @test PA.permute_indices(a, a2b) === b

            @test PA.relative_permutation(NoPermutation(), a) === a
            @test PA.relative_permutation(a, NoPermutation()) ===
                PA.inverse_permutation(a)

            if BENCHMARK_ARRAYS
                let x = (12, 42, 2)
                    print("@btime permute_indices...")
                    @btime PA.permute_indices($x, $a)
                end
            end

            x = Permutation((3, 1, 2))
            x2nothing = PA.relative_permutation(x, NoPermutation())
            @test PA.permute_indices(x, x2nothing) === Permutation((1, 2, 3))
        end
    end

    transpose_methods = (Transpositions.IsendIrecv(),
                         Transpositions.Alltoallv())

    @testset "transpose! $method" for method in transpose_methods
        T = Float64
        u1 = PencilArray{T}(undef, pen1)
        u2 = PencilArray{T}(undef, pen2)
        u3 = PencilArray{T}(undef, pen3)

        # Set initial random data.
        randn!(rng, u1)
        u1 .+= 10 * myrank
        u1_orig = copy(u1)

        # Direct u1 -> u3 transposition is not possible!
        @test_throws ArgumentError transpose!(u3, u1)

        # Transpose back and forth between different pencil configurations
        transpose!(u2, u1)
        @test compare_distributed_arrays(u1, u2)

        transpose!(u3, u2)
        @test compare_distributed_arrays(u2, u3)

        transpose!(u2, u3)
        @test compare_distributed_arrays(u2, u3)

        transpose!(u1, u2)
        @test compare_distributed_arrays(u1, u2)

        @test u1_orig == u1

        # Test transpositions without permutations.
        let pen2 = Pencil(pen1, decomp_dims=(1, 3))
            u2 = PencilArray{T}(undef, pen2)
            transpose!(u2, u1)
            @test compare_distributed_arrays(u1, u2)
        end

    end

    # Test arrays with extra dimensions.
    @testset "extra dimensions" begin
        T = Float32
        u1 = PencilArray{T}(undef, pen1, (3, 4))
        u2 = PencilArray{T}(undef, pen2, (3, 4))
        u3 = PencilArray{T}(undef, pen3, (3, 4))
        randn!(rng, u1)
        transpose!(u2, u1)
        @test compare_distributed_arrays(u1, u2)
        transpose!(u3, u2)
        @test compare_distributed_arrays(u2, u3)

        for v in (u1, u2, u3)
            @test check_iteration_order(v)
        end

        @inferred global_view(u1)
    end

    # Test slab (1D) decomposition.
    @testset "1D decomposition" begin
        T = Float32
        topo = MPITopology(comm, (Nproc, ))

        pen1 = Pencil(topo, Nxyz, (1, ))
        pen2 = Pencil(pen1, decomp_dims=(2, ))

        # Same decomposed dimension as pen2, but different permutation.
        pen3 = Pencil(pen2, permute=Permutation(3, 2, 1))

        u1 = PencilArray{T}(undef, pen1)
        u2 = PencilArray{T}(undef, pen2)
        u3 = PencilArray{T}(undef, pen3)

        randn!(rng, u1)
        transpose!(u2, u1)
        @test compare_distributed_arrays(u1, u2)

        transpose!(u3, u2)
        @test compare_distributed_arrays(u1, u3)
        @test check_iteration_order(u3)

        # Test transposition between two identical configurations.
        transpose!(u2, u2)
        @test compare_distributed_arrays(u1, u2)

        let v = similar(u2)
            @test u2.pencil === v.pencil
            transpose!(v, u2)
            @test compare_distributed_arrays(u1, v)
        end

        test_multiarrays(pen1, pen2, pen3)
    end

    begin
        MPITopologies = Pencils.MPITopologies
        periods = zeros(Int, length(proc_dims))
        comm_cart = MPI.Cart_create(comm, collect(proc_dims), periods, false)
        @inferred MPITopologies.create_subcomms(Val(2), comm_cart)
        @inferred PencilArrays.MPITopology{2}(comm_cart)
        @inferred MPITopologies.get_cart_ranks_subcomm(pen1.topology.subcomms[1])

        @inferred PencilArrays.to_local(pen2, (1:2, 1:2, 1:2), permute=true)

        @inferred PencilArrays.size_local(pen2, permute=true)

        T = Int
        @inferred PencilArray{T}(undef, pen2)
        @inferred PencilArray{T}(undef, pen2, (3, 4))

        @inferred PA.permute_indices(Nxyz, Permutation(2, 3, 1))
        @inferred PA.relative_permutation(Permutation(1, 2, 3),
                                          Permutation(2, 3, 1))
        @inferred PA.relative_permutation(Permutation(1, 2, 3), NoPermutation())

        u1 = PencilArray{T}(undef, pen1)
        u2 = PencilArray{T}(undef, pen2)

        @inferred Nothing gather(u2)
        @inferred transpose!(u2, u1)
        @inferred Transpositions._get_remote_indices(1, (2, 3), 8)
    end

    MPI.Finalize()
end

main()