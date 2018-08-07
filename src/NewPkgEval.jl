module NewPkgEval

    using BinaryBuilder
    using BinaryProvider
    using LightGraphs
    import Pkg.TOML
    using Pkg
    using Pkg: UUID
    using Dates
    using DataStructures
    import LibGit2

    const julia_url = "https://julialang-s3.julialang.org/bin/linux/x64/0.7/julia-0.7.0-alpha-linux-x86_64.tar.gz"
    downloads_dir(name) = joinpath(@__DIR__, "..", "deps", "downloads", name)
    julia_path() = joinpath(@__DIR__, "..", "deps", "julia")
    function obtain_julia()
        download_verify_unpack(
            julia_url,
            "8a1adb1fddbdd3e7a05c9ee8dfa322e2940dabe01b8acbb5806478643ed54ed9",
            julia_path();
            tarball_path=downloads_dir(basename(julia_url)),
            force=true
        )
    end

    function run_sandboxed_julia(args=``; kwargs...)
        obtain_julia()
        ispath(registry_path()) || error("Please run `NewPkgEval.get_registry()` first")
        jp = joinpath(julia_path(), first(readdir(julia_path())))
        runner = BinaryBuilder.UserNSRunner(pwd(),
            mappings=[
                jp => "/opt/julia",
                registry_path() => "/opt/Uncurated"
            ])
        BinaryBuilder.run_interactive(runner, `/opt/julia/bin/julia --color=yes $args`; kwargs...)
    end

    log_path() = joinpath(@__DIR__, "..", "logs")
    function run_sandboxed_test(pkg)
        log = joinpath(log_path(), "$pkg.log")
        c = quote
            mkpath("/root/.julia/registries")
            open("/etc/hosts", "w") do f
                println(f, "127.0.0.1\tlocalhost")
            end
            run(`mount -t devpts -o newinstance jrunpts /dev/pts`)
            run(`mount -o bind /dev/pts/ptmx /dev/ptmx`)
            run(`mount -t tmpfs tempfs /dev/shm`)
            run(`ln -s /opt/Uncurated/ /root/.julia/registries/Uncurated`)
            Pkg.add($pkg)
            Pkg.test($pkg)
        end
        arg = "using Pkg; eval($(repr(c)))"
        try
            open(log, "w") do f
                run_sandboxed_julia(`-e $arg`; stdout=f, stderr=f)
            end
            return true
        catch e
            return false
        end
    end

    const CSI = "\e["

    function show_result(io::IO, dg, queue, results)
        print(io, "Success: ")
        o, f, s = count(==(:ok), values(results)), count(==(:fail), values(results)),
            count(==(:skipped), values(results))
        q = length(queue)
        printstyled(io, o; color = :green)
        print(io, "\tFailed: ")
        printstyled(io, f; color = :red)
        print(io, "\tSkipped: ")
        printstyled(io, s; color = :yellow)
        print(io, "\tCurrent Frontier/Remaining: ")
        print(io, q, '/')
        print(io, length(vertices(dg.g)) - (o+f+s))
        println(io)
    end

    struct PkgEntry
        degree::Int
        idx::Int
    end
    Base.:<(a::PkgEntry, b::PkgEntry) = a.degree < b.degree

    function skip_pkg!(result, dg, to_skip)
        result[dg.names[to_skip]] = :skipped
        for revdep in inneighbors(dg.g, to_skip)
            if haskey(result, dg.names[revdep]) &&
                result[dg.names[revdep]] == :skipped
                continue
            end
            skip_pkg!(result, dg, revdep)
        end
    end

    const skip_list = [
        "AbstractAlgebra", # Hangs forever
        "DiscretePredictors", # Hangs forever
        "LinearLeastSquares", # Hangs forever
        "SLEEF", # Hangs forever
        "OrthogonalPolynomials", # Hangs forever
        "IndexableBitVectors",
        "LatinHypercubeSampling", # Hangs forever
        "DynamicalBilliards", # Hangs forever
        "ChangePrecision", # Hangs forever
        "Rectangle", # Hangs forever
        "Electron",
        "DotOverloading",
        "ValuedTuples",
        "HCubature",
        "SequentialMonteCarlo",
        "RequirementVersions",
        "NumberedLines",
        "LazyContext",
        "RecurUnroll", # deleted, hangs
        "TypedBools", # deleted, hangs
    ]

    const ok_list = [
        "BinDeps", # Not really ok, but packages may list it just as a fallback
        "InteractiveUtils", # We rely on LD_LIBRARY_PATH working for the moment
        "Homebrew",
        "WinRPM",
        "NamedTuples", # As requested by quinnj
        "Compat"
    ]

    function run_all(dg, ninstances, result = Dict{String, Symbol}())
        frontier = BitSet()
        pkgs = copy(dg.names)
        running = Vector{Union{Nothing, Symbol}}(nothing, ninstances)
        times = DateTime[now() for i = 1:ninstances]
        processed = BitSet()
        cond = Condition()
        queue = binary_maxheap(PkgEntry)
        completed = Channel(Inf)
        # Add packages without dependencies to the frontier
        for x in ok_list
            result[x] = :ok
            put!(completed, findfirst(==(x), dg.names))
        end
        for p in filter(v->length(outneighbors(dg.g, v)) == 0, vertices(dg.g))
            (dg.names[p] in skip_list) && continue
            (haskey(result, dg.names[p])) && continue
            push!(queue, PkgEntry(length(inneighbors(dg.g, p)), p))
        end
        for x in skip_list
            skip_pkg!(result, dg, findfirst(==(x), dg.names))
        end
        done = false
        processing = false
        all_workers = Task[]
        did_signal_workers = false
        function stop_work()
            if !done
                (done = true; notify(cond); put!(completed, -1))
                if !did_signal_workers
                    for task in all_workers
                        task == current_task() && continue
                        !Base.istaskdone(task) || continue
                        try; schedule(task, InterruptException(); error=true); catch; end
                    end
                    did_signal_workers = true
                end
            end
        end
        @sync begin
            @async begin
                try
                    buf = IOBuffer()
                    io = IOContext(buf, :color => true)
                    while !isempty(queue) || !all(==(nothing), running) || isready(completed) || processing
                        show_result(io, dg, queue, result)
                        for i = 1:ninstances
                            r = running[i]
                            if r === nothing
                                println(io, "Worker $i: -------")
                            else
                                println(io, "Worker $i: $(r) running for ", Dates.canonicalize(Dates.CompoundPeriod(now() - times[i])))
                            end
                        end
                        print(String(take!(buf)))
                        sleep(1)
                        print(io, "$(CSI)$(ninstances+1)A$(CSI)1G$(CSI)0J")
                    end
                    stop_work()
                    println("done")
                catch e
                    stop_work()
                    !isa(e, InterruptException) && rethrow(e)
                end
            end
            # Scheduler
            @async begin
                try
                    while !done
                        pkgno = take!(completed)
                        pkgno == -1 && break
                        processing = true
                        push!(processed, pkgno)
                        for revdep in inneighbors(dg.g, pkgno)
                            if result[dg.names[pkgno]] != :ok
                                skip_pkg!(result, dg, revdep)
                            else
                                (revdep in processed) && continue
                                # Last dependency to finish adds it to
                                # the frontier
                                all_processed = true
                                for dep in outneighbors(dg.g, revdep)
                                    if !(dep in processed) || result[dg.names[dep]] != :ok
                                        all_processed = false
                                        break
                                    end
                                end
                                all_processed || continue
                                haskey(result, dg.names[revdep]) && continue
                                push!(queue, PkgEntry(length(inneighbors(dg.g, revdep)), revdep))
                            end
                        end
                        notify(cond)
                        processing = false
                    end
                catch e
                    stop_work()
                    !isa(e, InterruptException) && rethrow(e)
                end
            end
            # Workers
            for i = 1:ninstances
                push!(all_workers, @async begin
                    try
                        while !done
                            if isempty(queue)
                                wait(cond)
                                continue
                            end
                            pkgno = pop!(queue).idx
                            pkg = dg.names[pkgno]
                            running[i] = pkg
                            times[i] = now()
                            result[pkg] = run_sandboxed_test(pkg) ? :ok : :fail
                            running[i] = nothing
                            put!(completed, pkgno)
                        end
                    catch e
                        stop_work()
                        !isa(e, InterruptException) && rethrow(e)
                    end
                end)
            end
        end
        result
    end

    function run_pkg_deps(pkg, dg, ninstances)
        result = Dict{String, Symbol}()
        nbs = unique(LightGraphs.neighborhood(dg.g, findfirst(==(pkg), dg.names), typemax(Int)))
        for pkg in dg.names[filter(x->!(x in nbs), 1:length(dg.names))]
            result[pkg] = :skipped
        end
        run_all(dg, ninstances, result)
    end

    function read_all_pkgs()
        pkgs = Tuple{String, UUID, String}[]
        for registry in (registry_path(),)
            open(joinpath(registry, "Registry.toml")) do io
                # skip forward until [packages] section
                for line in eachline(io)
                    occursin(r"^ \s* \[ \s* packages \s* \] \s* $"x, line) && break
                end
                for line in eachline(io)
                    m = match(Pkg.Types.line_re, line)
                    m == nothing &&
                            error("misformatted registry.toml package entry: $line")
                    uuid = UUID(m.captures[1])
                    name = Base.unescape_string(m.captures[2])
                    name == "julia" && continue
                    path = abspath(registry, Base.unescape_string(m.captures[3]))
                    push!(pkgs, (name, uuid, path))
                end
            end
        end
        pkgs
    end

    registry_path() = joinpath(@__DIR__, "..", "work", "registry")

    function get_registry()
        if !isdir(registry_path())
            creds = LibGit2.CachedCredentials()
            url = Pkg.Types.DEFAULT_REGISTRIES["Uncurated"]
            repo = Pkg.GitTools.clone(url, registry_path(); header = "registry Uncurated from $(repr(url))", credentials = creds)
            close(repo)
        else
            errors = Pkg.API.do_update_registry!(registry_path())
            Pkg.API.print_errors(errors)
        end
    end

    struct PkgDepGraph
        vertex_map::Dict{UUID, Int}
        uuid::Vector{UUID}
        names::Vector{String}
        g::LightGraphs.SimpleGraphs.SimpleDiGraph
    end

    function read_stdlib()
        stdlib_path = joinpath(julia_path(), first(readdir(julia_path())),
                "share/julia/stdlib/v0.7")
        ret = Tuple{String, UUID, Vector{UUID}}[]
        stdlibs = readdir(stdlib_path)
        for stdlib in stdlibs
            proj = Pkg.read_project(joinpath(stdlib_path, stdlib, "Project.toml"))
            deps = UUID.(collect(values(proj["deps"])))
            push!(ret, (proj["name"], UUID(proj["uuid"]), deps))
        end
        ret
    end

    function PkgDepGraph(pkgs)
        # Add packages
        vertex_map = Dict(pkg[2] => i for (i, pkg) in enumerate(pkgs))
        uuids = map(x->x[2], pkgs)
        names = map(x->x[1], pkgs)
        # Add stdlibs to vertex map
        stdlibs = read_stdlib()
        stdlib_uuids = Set(x[2] for x in stdlibs)
        @Base.show stdlib_uuids
        for (i, (name, uuid, _)) in enumerate(stdlibs)
            x = findfirst(==(uuid), uuids)
            if x === nothing
                push!(names, name)
                push!(uuids, uuid)
                vertex_map[uuid] = length(names)
            end
        end
        g = LightGraphs.SimpleGraphs.SimpleDiGraph(length(names))
        for (_, uuid, deps) in stdlibs
            for dep in deps
                add_edge!(g, vertex_map[uuid], vertex_map[dep])
            end
        end
        for (name, uuid, path) in pkgs
            (uuid in stdlib_uuids) && continue
            vers = Pkg.Operations.load_versions(path)
            max_ver = maximum(keys(vers))
            data = Pkg.Operations.load_package_data(UUID, joinpath(path, "Deps.toml"), max_ver)
            data === nothing && continue
            for (k,v) in data
                if !haskey(vertex_map, v)
                    @warn "Dependency $k ($v) not in registry"
                    continue
                end
                add_edge!(g, vertex_map[uuid], vertex_map[v])
            end
        end
        # Arbitrarily break dependency cycles
        cycs = LightGraphs.simplecycles(g)
        for cyc in cycs
            rem_edge!(g, cyc[end], cyc[1])
        end
        PkgDepGraph(vertex_map, uuids, names, g)
    end

    function no_dep_pkgs(g::PkgDepGraph)
        filter(v->length(outneighbors(g.g, v)) == 0, vertices(g.g))
    end

    function analyze_results(dg, result)
        # Print the top packages by recursive benefit if fixed
        failed_pkgs = filter(((k,v),)->v == :fail, result)
        r = Dict(begin
            id = findfirst(==(k), dg.names)
            # Avoid cycles
            visited = BitSet()
            stack = Int[id]
            push!(visited, id)
            n = 0
            while !isempty(stack)
                x = pop!(stack)
                for y in inneighbors(dg.g, x)
                    (y in visited) && continue
                    push!(visited, y)
                    push!(stack, y)
                    n += 1
                end
            end
            k => n
        end for (k, v) in failed_pkgs)
        sort(collect(r), by = x->x[2], rev = true)
    end

    function analyze_results_pkg(pkg, dg, result)
        nbs = unique(LightGraphs.neighborhood(dg.g, findfirst(==(pkg), dg.names), typemax(Int)))
        nbs_names = dg.names[nbs]
        nresult = filter(((k,v),)->k in nbs_names, result)
        analyze_results(dg, nresult)
    end

end # module