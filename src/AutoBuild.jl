export build_tarballs, autobuild, print_artifacts_toml, build
import GitHub: gh_get_json, DEFAULT_API
import SHA: sha256
using Pkg.TOML
import Registrator

"""
    build_tarballs(ARGS, src_name, src_version, sources, script, platforms,
                   products, dependencies; kwargs...)

This should be the top-level function called from a `build_tarballs.jl` file.
It takes in the information baked into a `build_tarballs.jl` file such as the
`sources` to download, the `products` to build, etc... and will automatically
download, build and package the tarballs, generating a `build.jl` file when
appropriate.  Note that `ARGS` should be the top-level Julia `ARGS` command-
line arguments object.  This function does some rudimentary parsing of the
`ARGS`, call it with `--help` in the `ARGS` to see what it can do.
"""
function build_tarballs(ARGS, src_name, src_version, sources, script,
                        platforms, products, dependencies; kwargs...)
    # See if someone has passed in `--help`, and if so, give them the
    # assistance they so clearly long for
    if "--help" in ARGS
        println(strip("""
        Usage: build_tarballs.jl [target1,target2,...] [--verbose]
                                 [--debug] [--deploy] [--help]

        Options:
            targets             By default `build_tarballs.jl` will build a tarball
                                for every target within the `platforms` variable.
                                To override this, pass in a list of comma-separated
                                target triplets for each target to be built.  Note
                                that this can be used to build for platforms that
                                are not listed in the 'default list' of platforms
                                in the build_tarballs.jl script.

            --verbose           This streams compiler output to stdout during the
                                build which can be very helpful for finding bugs.
                                Note that it is colorized if you pass the
                                --color=yes option to julia, see examples below.

            --debug             This causes a failed build to drop into an
                                interactive shell for debugging purposes.

            --deploy=<repo>     Deploy the built binaries to a github release of
                                an autogenerated wrapper code repository.  Uses
                                `github.com/JuliaBinaryWrappers/<name>_jll.jl` by
                                default, unless `<repo>` is set, in which case it
                                should be set as `<owner>/<name>_jll`.

            --register=<depot>  Register into the given depot.  If no path is
                                given, defaults to `~/.julia`.  Registration
                                requires deployment, so using `--register`
                                without `--deploy` is an error.

            --help              Print out this message.

        Examples:
            julia --color=yes build_tarballs.jl --verbose
                This builds all tarballs, with colorized output.

            julia build_tarballs.jl x86_64-linux-gnu,i686-linux-gnu
                This builds two tarballs for the two platforms given, with a
                minimum of output messages.
        """))
        return nothing
    end

    function check_flag(flag)
        flag_present = flag in ARGS
        ARGS = filter!(x -> x != flag, ARGS)
        return flag_present
    end

    function extract_flag(flag, val = nothing)
        for f in ARGS
            if startswith(f, flag)
                # Check if it's just `--flag` or if it's `--flag=foo`
                if f != flag
                    val = split(f, '=')[2]
                end

                # Drop this value from our ARGS
                ARGS = filter!(x -> x != f, ARGS)
                return (true, val)
            end
        end
        return (false, val)
    end

    # This sets whether we should build verbosely or not
    verbose = check_flag("--verbose")

    # This sets whether we drop into a debug shell on failure or not
    debug = check_flag("--debug")

    # This sets whether we are going to deploy our binaries to GitHub releases
    deploy, deploy_repo = extract_flag("--deploy", "JuliaBinaryWrappers/$(src_name)_jll.jl")

    # This sets whether we are going to register, and if so, which
    register, register_path = extract_flag("--register", Pkg.depots1())
    if register && !deploy
        error("Cannot register without deploying!")
    end
    if deploy
        code_dir = joinpath(Pkg.depots1(), "dev", "$(src_name)_jll")

        # Shove them into `kwargs` so that we are conditionally passing them along
        kwargs = (; kwargs..., code_dir = code_dir)
    end

    # If the user passed in a platform (or a few, comma-separated) on the
    # command-line, use that instead of our default platforms
    if length(ARGS) > 0
        platforms = platform_key_abi.(split(ARGS[1], ","))
    end

    # Check to make sure we have the necessary environment stuff
    if deploy
        # Check to see if we've already got a wrapper package within the Registry,
        # choose a version number that is greater than anything else existent.
        build_version = get_next_wrapper_version(src_name, src_version)
        if verbose
            @info("Building and deploying version $(build_version) to $(deploy_repo)")
        end
        tag = "$(src_name)-v$(build_version)"

        # Get our github authentication, and determine the username from that
        gh_auth = github_auth(;allow_anonymous=false)
        gh_username = GitHub.gh_get_json(GitHub.DEFAULT_API, "/user"; auth=gh_auth)["login"]

        # First, ensure the GH repo exists
        try
            # This throws if it does not exist
            GitHub.repo(deploy_repo; auth=gh_auth)

            # If it does exist, then check if it exists on disk, if not, clone it down
            if !isdir(code_dir)
                # If it does exist, clone it down:
                @info("Cloning wrapper code repo from https://github.com/$(deploy_repo) into $(code_dir)")
                LibGit2.clone("git@github.com:$(deploy_repo)", code_dir)
            end
        catch e
            # If it doesn't exist, create it
            owner = GitHub.Owner("JuliaBinaryWrappers", true)
            @info("Creating new wrapper code repo at https://github.com/$(deploy_repo)")
            GitHub.create_repo(owner, "$(src_name)_jll.jl"; auth=gh_auth)

            # Initialize empty repository
            LibGit2.init(code_dir)
        end
    end

    # Build the given platforms using the given sources
    @info("Building for $(join(triplet.(platforms), ", "))")
    build_output_meta = autobuild(pwd(), src_name, src_version, sources, script, platforms,
                                  products, dependencies; verbose=verbose, debug=debug, kwargs...)

    if deploy
        if verbose
            @info("Committing and pushing $(src_name)_jll.jl wrapper code version $(build_version)...")
        end

        # The location the binaries will be available from
        bin_path = "https://github.com/$(deploy_repo)/releases/download/$(tag)"
        build_jll_package(src_name, build_version, code_dir, build_output_meta, dependencies, bin_path; verbose=verbose)

        # Next, push up the wrapper code repository
        wrapper_repo = LibGit2.GitRepo(code_dir)
        LibGit2.add!(wrapper_repo, ".")
        LibGit2.commit(wrapper_repo, "$(src_name)_jll build $(build_version)")
        creds = LibGit2.UserPasswordCredential(
            deepcopy(gh_username),
            deepcopy(gh_auth.token),
        )
        try
            LibGit2.push(
                wrapper_repo;
                refspecs=["refs/heads/master"],
                remoteurl="https://github.com/$(deploy_repo).git",
                credentials=creds,
            )
        finally
            Base.shred!(creds)
        end

        wrapper_tree_hash = bytes2hex(Pkg.GitTools.tree_hash(code_dir))

        if verbose
            @info("Registering new wrapper code version $(build_version)...")
        end

        # Register into our `General` fork
        if register
            cache = Registrator.RegEdit.RegistryCache(joinpath(Pkg.depots1(), "registries_binarybuilder"))
            registry_url = "https://$(gh_username):$(gh_auth.token)@github.com/JuliaRegistries/General"
            cache.registries[registry_url] = Base.UUID("23338594-aafe-5451-b93e-139f81909106")
            project = Pkg.Types.Project(build_project_dict(src_name, build_version, dependencies))
            reg_branch = Registrator.RegEdit.register(
                "https://github.com/$(deploy_repo).git",
                project,
                wrapper_tree_hash;
                registry=registry_url,
                cache=cache,
                push=true,
            )
            if haskey(reg_branch.metadata, "error")
                @error(reg_branch.metadata["error"])
            end

            # Open pull request against General
            params = Dict(
                "base" => "master",
                "head" => reg_branch.branch,
                "maintainer_can_modify" => true,
                "title" => "JLL Registration: $(deploy_repo)-v$(build_version)",
                "body" => """
                Autogenerated JLL package registration

                * Registering JLL package $(basename(deploy_repo))
                * Repository: https://github.com/$(deploy_repo)
                * Version: v$(build_version)
                """
            )
            create_or_update_pull_request("JuliaRegistries/General", params; auth=gh_auth)
        end

        # Upload the binaries
        if verbose
            @info("Deploying binaries to release $(tag) on $(deploy_repo) via `ghr`...")
        end
        upload_to_github_releases(deploy_repo, tag, joinpath(pwd(), "products"); verbose=verbose)
    end

    return build_output_meta
end

function upload_to_github_releases(repo, tag, path; attempts::Int = 3, verbose::Bool = false)
    for attempt in 1:attempts
        try
            run(`ghr -replace -u $(dirname(repo)) -r $(basename(repo)) $(tag) $(path)`)
            return
        catch
            if verbose
                @info("`ghr` upload step failed, beginning attempt #$(attempt)...")
            end
        end
    end
    error("Unable to upload $(path) to GitHub repo $(repo) on tag $(tag)")
end

function get_next_wrapper_version(src_name, src_version)
    ctx = Pkg.Types.Context()

    # If it does, we need to bump the build number up to the next value
    build_number = 0
    if any(isfile(joinpath(p, "Package.toml")) for p in Pkg.Operations.registered_paths(ctx.env, jll_uuid("$(src_name)_jll")))
        # Find largest version number that matches ours in the registered paths
        versions = VersionNumber[]
        for path in Pkg.Operations.registered_paths(ctx.env, jll_uuid("$(src_name)_jll"))
            append!(versions, Pkg.Compress.load_versions(joinpath(path, "Versions.toml")))
        end
        versions = filter(v -> (v.major == src_version.major) &&
                            (v.minor == src_version.minor) &&
                            (v.patch == src_version.patch) &&
                            (v.build isa Tuple{<:UInt}), versions)
        # Our build number must be larger than the maximum already present in the registry
        if !isempty(versions)
            build_number = first(maximum(versions).build) + 1
        end
    end

    # Construct build_version (src_version + build_number)
    build_version = VersionNumber(src_version.major, src_version.minor,
                         src_version.patch, src_version.prerelease, (build_number,))
end


"""
    autobuild(dir::AbstractString, src_name::AbstractString,
              src_version::VersionNumber, sources::Vector,
              script::AbstractString, platforms::Vector,
              products::Vector, dependencies::Vector;
              verbose = false, debug = false,
              skip_audit = false, ignore_audit_errors = true,
              autofix = true, code_dir = nothing,
              require_license = true, kwargs...)

Runs the boiler plate code to download, build, and package a source package
for a list of platforms.  `src_name` represents the name of the source package
being built (and will set the name of the built tarballs), `src_version` is the
version of the source package. `platforms` is a list of platforms to build for,
`sources` is a list of tuples giving `(url, hash)` of all sources to download
and unpack before building begins, `script` is a string representing a shell
script to run to build the desired products, which are listed as `Product`
objects. `dependencies` gives a list of JLL dependency packages as strings or
`PackageSpec`s that should be installed before building begins. Setting `debug`
to `true` will cause a failed build to drop into an interactive shell so that
the build can be inspected easily. `skip_audit` will disable the typical audit
that occurs at the end of a build, while `ignore_audit_errors` by default will
not kill a build even if a problem is found.  `autofix` gives BinaryBuilder
permission to automatically fix issues it finds.  `code_dir` determines where
autogenerated JLL packages will be put, and `require_license` enables a special
audit pass that requires licenses to be installed by all packages.
"""
function autobuild(dir::AbstractString,
                   src_name::AbstractString,
                   src_version::VersionNumber,
                   sources::Vector,
                   script::AbstractString,
                   platforms::Vector,
                   products::Vector{<:Product},
                   dependencies::Vector;
                   verbose::Bool = false,
                   debug::Bool = false,
                   skip_audit::Bool = false,
                   ignore_audit_errors::Bool = true,
                   autofix::Bool = true,
                   code_dir::Union{String,Nothing} = nothing,
                   require_license::Bool = true,
                   kwargs...)
    # If we're on CI and we're not verbose, schedule a task to output a "." every few seconds
    if (haskey(ENV, "TRAVIS") || haskey(ENV, "CI")) && !verbose
        run_travis_busytask = true
        travis_busytask = @async begin
            # Don't let Travis think we're asleep...
            @info("Brewing a pot of coffee for Travis...")
            while run_travis_busytask
                sleep(4)
                print(".")
            end
        end
    end

    # This is what we'll eventually return
    build_output_meta = Dict()

    # Resolve dependencies into PackageSpecs now, ensuring we have UUIDs for all deps
    ctx = Pkg.Types.Context()
    pkgspecify(name::String) = Pkg.Types.PackageSpec(;name=name)
    pkgspecify(ps::Pkg.Types.PackageSpec) = ps
    dependencies = pkgspecify.(dependencies)
    Pkg.Types.registry_resolve!(ctx.env, dependencies)

    # If we end up packaging any local directories into tarballs, we'll store them here
    mktempdir() do tempdir
        # We must prepare our sources.  Download them, hash them, etc...
        sources = Any[s for s in sources]
        for idx in 1:length(sources)
            # If the given source is a local path that is a directory, package it up and insert it into our sources
            if typeof(sources[idx]) <: AbstractString
                if !isdir(sources[idx])
                    error("Sources must either be a pair (url => hash) or a local directory")
                end

                # Package up this directory and calculate its hash
                tarball_path = joinpath(tempdir, basename(sources[idx]) * ".tar.gz")
                package(sources[idx], tarball_path)
                tarball_hash = open(tarball_path, "r") do f
                    bytes2hex(sha256(f))
                end

                # Move it to a filename that has the hash as a part of it (to avoid name collisions)
                tarball_pathv = joinpath(tempdir, string(tarball_hash, "-", basename(sources[idx]), ".tar.gz"))
                mv(tarball_path, tarball_pathv)

                # Now that it's packaged, store this into sources[idx]
                sources[idx] = (tarball_pathv => tarball_hash)
            elseif typeof(sources[idx]) <: Pair
                src_url, src_hash = sources[idx]

                # If it's a .git url, clone it
                if endswith(src_url, ".git")
                    src_path = storage_dir("downloads", basename(src_url))

                    # If this git repository already exists, ensure that its origin remote actually matches
                    if isdir(src_path)
                        origin_url = LibGit2.with(LibGit2.GitRepo(src_path)) do repo
                            LibGit2.url(LibGit2.get(LibGit2.GitRemote, repo, "origin"))
                        end

                        # If the origin url doesn't match, wipe out this git repo.  We'd rather have a
                        # thrashed cache than an incorrect cache.
                        if origin_url != src_url
                            rm(src_path; recursive=true, force=true)
                        end
                    end

                    if isdir(src_path)
                        # If we didn't just mercilessly obliterate the cached git repo, use it!
                        LibGit2.with(LibGit2.GitRepo(src_path)) do repo
                            LibGit2.fetch(repo)
                        end
                    else
                        # If there is no src_path yet, clone it down.
                        repo = LibGit2.clone(src_url, src_path; isbare=true)
                    end
                else
                    if isfile(src_url)
                        # Immediately abspath() a src_url so we don't lose track of
                        # sources given to us with a relative path
                        src_path = abspath(src_url)

                        # And if this is a locally-sourced tarball, just verify
                        verify(src_path, src_hash; verbose=verbose)
                    else
                        # Otherwise, download and verify
                        src_path = storage_dir("downloads", string(src_hash, "-", basename(src_url)))
                        download_verify(src_url, src_hash, src_path; verbose=verbose)
                    end
                end

                # Now that it's downloaded, store this into sources[idx]
                sources[idx] = (src_path => src_hash)
            else
                error("Sources must be either a `URL => hash` pair, or a path to a local directory")
            end
        end

        # Our build products will go into ./products
        out_path = joinpath(dir, "products")
        try mkpath(out_path) catch; end

        # Convert from tuples to arrays, if need be
        if isempty(sources)
            src_paths, src_hashes = (String[], String[])
        else
            src_paths, src_hashes = collect.(collect(zip(sources...)))
        end

        for platform in platforms
            # We build in a platform-specific directory
            build_path = joinpath(pwd(), "build", triplet(platform))
            mkpath(build_path)

            prefix = setup_workspace(
                build_path,
                src_paths,
                src_hashes;
                verbose=verbose,
            )
            artifact_paths = setup_dependencies(prefix, dependencies, platform)

            # Create a runner to work inside this workspace with the nonce built-in
            ur = preferred_runner()(
                prefix.path;
                cwd = "/workspace/srcdir",
                platform = platform,
                verbose = verbose,
                workspaces = [
                    joinpath(prefix, "metadir") => "/meta",
                ],
                compiler_wrapper_dir = joinpath(prefix, "compiler_wrappers"),
                src_name = src_name,
                extract_kwargs(kwargs, (:preferred_gcc_version,:compilers))...,
            )

            # Set up some bash traps
            trapper_wrapper = """
            # Stop if we hit any errors.
            set -e

            # If we're running as `bash`, then use the `DEBUG` and `ERR` traps
            if [ \$(basename \$0) = "bash" ]; then
                trap "trap - DEBUG; set +e +x; auto_install_license; save_env" EXIT
                trap "RET=\\\$?; trap - DEBUG; trap - EXIT; set +e +x; echo Previous command exited with \\\$RET >&2; save_srcdir; save_env; exit \\\$RET" INT TERM ERR

                # Swap out srcdir from underneath our feet if we've got our `ERR`
                # traps set; if we don't have this, we get very confused.  :P
                tmpify_srcdir

                # Start saving everything into our history
                trap save_history DEBUG
            else
                # If we're running in `sh` or something like that, we need a
                # slightly slimmer set of traps. :(
                trap "echo Previous command exited with \$? >&2; set +e +x; save_env" EXIT INT TERM
            fi

            $(script)
            """

            dest_prefix = Prefix(joinpath(prefix.path, "destdir"))
            did_succeed = with_logfile(dest_prefix, "$(src_name).log") do io
                run(ur, `/bin/bash -l -c $(trapper_wrapper)`, io; verbose=verbose)
            end
            if !did_succeed
                if debug
                    @warn("Build failed, launching debug shell")
                    run_interactive(ur, `/bin/bash -l -i`)
                end
                msg = "Build for $(src_name) on $(triplet(platform)) did not complete successfully\n"
                error(msg)
            end

            # Run an audit of the prefix to ensure it is properly relocatable
            if !skip_audit
                audit_result = audit(dest_prefix, src_name;
                                     platform=platform, verbose=verbose,
                                     autofix=autofix, require_license=require_license)
                if !audit_result && !ignore_audit_errors
                    msg = replace("""
                    Audit failed for $(dest_prefix.path).
                    Address the errors above to ensure relocatability.
                    To override this check, set `ignore_audit_errors = true`.
                    """, '\n' => ' ')
                    error(strip(msg))
                end
            end

            # Finally, error out if something isn't satisfied
            unsatisfied_so_die = false
            for p in products
                if !satisfied(p, dest_prefix; verbose=verbose, platform=platform)
                    if !verbose
                        # If we never got a chance to see the verbose output, give it here:
                        locate(p, dest_prefix; verbose=true, platform=platform)
                    end
                    @error("Built $(src_name) but $(variable_name(p)) still unsatisfied:")
                    unsatisfied_so_die = true
                end
            end
            if unsatisfied_so_die
                error("Cannot continue with unsatisfied build products!")
            end

            # We also need to capture some info about each product
            products_info = Dict()
            for p in products
                product_path = locate(p, dest_prefix; platform=platform)
                products_info[p] = Dict("path" => relpath(product_path, dest_prefix.path))
                if p isa LibraryProduct
                    products_info[p]["soname"] = something(
                        get_soname(product_path),
                        basename(product_path),
                    )
                end
            end

            # Unsymlink all the deps from the dest_prefix
            cleanup_dependencies(prefix, artifact_paths)

            # Cull empty directories, for neatness' sake, unless auditing is disabled
            if !skip_audit
                for (root, dirs, files) = walkdir(dest_prefix.path; topdown=false)
                    # We do readdir() here because `walkdir()` does not do a true in-order traversal
                    if isempty(readdir(root))
                        rm(root)
                    end
                end
            end

            # Once we're built up, go ahead and package this dest_prefix out
            tarball_path, tarball_hash, git_hash = package(
                dest_prefix,
                joinpath(out_path, src_name),
                src_version;
                platform=platform,
                verbose=verbose,
                force=true,
            )

            build_output_meta[platform] = (
                basename(tarball_path),
                tarball_hash,
                git_hash,
                products_info,
            )

            # Destroy the workspace
            rm(prefix.path; recursive=true)

            # If the whole build_path is empty, then remove it too.  If it's not, it's probably
            # because some other build is doing something simultaneously with this target, and we
            # don't want to mess with their stuff.
            if isempty(readdir(build_path))
                rm(build_path; recursive=true)
            end
        end
    end

    if (haskey(ENV, "TRAVIS") || haskey(ENV, "CI")) && !verbose
        run_travis_busytask = false
        wait(travis_busytask)
        println()
    end

    # Return our product hashes
    return build_output_meta
end

function build_jll_package(src_name::String, build_version::VersionNumber, code_dir::String, build_output_meta::Dict, dependencies::Vector, bin_path::String; verbose::Bool = false)
    # Make way, for prince artifacti
    mkpath(joinpath(code_dir, "src", "wrappers"))

    platforms = keys(build_output_meta)
    for platform in platforms
        if verbose
            @info("Generating jll package for $(triplet(platform)) in $(code_dir)")
        end

        # Extract this platform's information.  Each of these things can be platform-specific
        # (including the set of products!) so be general here.
        tarball_name, tarball_hash, git_hash, products_info = build_output_meta[platform]

        # Add an Artifacts.toml
        artifacts_toml = joinpath(code_dir, "Artifacts.toml")
        download_info = Tuple[
            (joinpath(bin_path, tarball_name), tarball_hash),
        ]
        bind_artifact!(artifacts_toml, src_name, git_hash; platform=platform, download_info=download_info, force=true)

        # Generate the platform-specific wrapper code
        open(joinpath(code_dir, "src", "wrappers", "$(triplet(platform)).jl"), "w") do io
            println(io, "# Autogenerated wrapper script for $(src_name)_jll for $(triplet(platform))")
            if !isempty(products_info)
                println(io, """
                export $(join(variable_name.(keys(products_info)), ", "))
                """)
            end
            for dep in dependencies
                println(io, "using $(dep)")
            end

            # The LIBPATH is called different things on different platforms
            if platform isa Windows
                LIBPATH_env = "PATH"
                pathsep = ';'
            elseif platform isa MacOS
                LIBPATH_env = "DYLD_FALLBACK_LIBRARY_PATH"
                pathsep = ':'
            else
                LIBPATH_env = "LD_LIBRARY_PATH"
                pathsep = ':'
            end

            println(io, """
            ## Global variables
            PATH = ""
            LIBPATH = ""
            LIBPATH_env = $(repr(LIBPATH_env))
            """)

            # Next, begin placing products
            function global_declaration(p::LibraryProduct, p_info::Dict)
                # A library product's public interface is a handle
                return """
                # This will be filled out by __init__()
                $(variable_name(p))_handle = C_NULL

                # This must be `const` so that we can use it with `ccall()`
                const $(variable_name(p)) = $(repr(p_info["soname"]))
                """
            end

            function global_declaration(p::ExecutableProduct, p_info::Dict)
                vp = variable_name(p)
                # An executable product's public interface is a do-block wrapper function
                return """
                function $(vp)(f::Function; adjust_PATH::Bool = true, adjust_LIBPATH::Bool = true)
                    global PATH, LIBPATH
                    env_mapping = Dict{String,String}()
                    if adjust_PATH
                        if !isempty(get(ENV, "PATH", ""))
                            env_mapping["PATH"] = string(PATH, $(repr(pathsep)), ENV["PATH"])
                        else
                            env_mapping["PATH"] = PATH
                        end
                    end
                    if adjust_LIBPATH
                        if !isempty(get(ENV, LIBPATH_env, ""))
                            env_mapping[LIBPATH_env] = string(LIBPATH, $(repr(pathsep)), ENV[LIBPATH_env])
                        else
                            env_mapping[LIBPATH_env] = LIBPATH
                        end
                    end
                    withenv(env_mapping...) do
                        f($(vp)_path)
                    end
                end
                """
            end

            function global_declaration(p::FileProduct, p_info::Dict)
                return """
                # This will be filled out by __init__()
                $(variable_name(p)) = ""
                """
            end

            # Create relative path mappings that are compile-time constant, and mutable
            # mappings that are initialized by __init__() at load time.
            for (p, p_info) in products_info
                vp = variable_name(p)
                println(io, """
                # Relative path to `$(vp)`
                const $(vp)_splitpath = $(repr(splitpath(p_info["path"])))

                # This will be filled out by __init__() for all products, as it must be done at runtime
                $(vp)_path = ""

                # $(vp)-specific global declaration
                $(global_declaration(p, p_info))
                """)
            end

            print(io, """
            \"\"\"
            Open all libraries
            \"\"\"
            function __init__()
                global prefix = abspath(joinpath(@__DIR__, ".."))

                # Initialize PATH and LIBPATH environment variable listings
                global PATH_list, LIBPATH_list
            """)

            if !isempty(dependencies)
                println(io, """
                    append!.(Ref(PATH_list), ($(join(["$(dep).PATH_list" for dep in dependencies], ", ")),))
                    append!.(Ref(LIBPATH_list), ($(join(["$(dep).LIBPATH_list" for dep in dependencies], ", ")),))
                """)
            end

            for (p, p_info) in products_info
                vp = variable_name(p)

                # Initialize $(vp)_path
                println(io, """
                    global $(vp)_path = abspath(joinpath(artifact"$(src_name)", $(vp)_splitpath...))
                """)

                # If `p` is a `LibraryProduct`, dlopen() it right now!
                if p isa LibraryProduct
                    println(io, """
                        # Manually `dlopen()` this right now so that future invocations
                        # of `ccall` with its `SONAME` will find this path immediately.
                        global $(vp)_handle = dlopen($(vp)_path)
                        push!(LIBPATH_list, dirname($(vp)_path))
                    """)
                elseif p isa ExecutableProduct
                    println(io, "    push!(PATH_list, dirname($(vp)_path))")
                elseif p isa FileProduct
                    println(io, "    global $(vp) = $(vp)_path")
                end
            end

            println(io, """
                # Filter out duplicate and empty entries in our PATH and LIBPATH entries
                filter!(!isempty, unique!(PATH_list))
                filter!(!isempty, unique!(LIBPATH_list))
                global PATH = join(PATH_list, $(repr(pathsep)))
                global LIBPATH = join(LIBPATH_list, $(repr(pathsep)))

                # Add each element of LIBPATH to our DL_LOAD_PATH (necessary on platforms
                # that don't honor our "already opened" trick)
                #for lp in LIBPATH_list
                #    push!(DL_LOAD_PATH, lp)
                #end
            end  # __init__()
            """)
        end
    end

    # Generate target-demuxing main source file.
    open(joinpath(code_dir, "src", "$(src_name)_jll.jl"), "w") do io
        print(io, """
        module $(src_name)_jll
        using Pkg, Pkg.BinaryPlatforms, Pkg.Artifacts, Libdl
        import Base: UUID

        # We put these inter-JLL-package API values here so that they are always defined, even if there
        # is no underlying wrapper held within this JLL package.
        const PATH_list = String[]
        const LIBPATH_list = String[]

        # Load Artifacts.toml file
        artifacts_toml = joinpath(@__DIR__, "..", "Artifacts.toml")

        # Extract all platforms
        artifacts = Pkg.Artifacts.load_artifacts_toml(artifacts_toml; pkg_uuid=$(repr(jll_uuid("$(src_name)_jll"))))
        platforms = [Pkg.Artifacts.unpack_platform(e, $(repr(src_name)), artifacts_toml) for e in artifacts[$(repr(src_name))]]

        # Filter platforms based on what wrappers we've generated on-disk
        platforms = filter(p -> isfile(joinpath(@__DIR__, "wrappers", triplet(p) * ".jl")), platforms)

        # From the available options, choose the best platform
        best_platform = select_platform(Dict(p => triplet(p) for p in platforms))

        # Silently fail if there's no binaries for this platform
        if best_platform === nothing
            @debug("Unable to load $(src_name); unsupported platform \$(triplet(platform_key_abi()))")
        else
            # Load the appropriate wrapper
            include(joinpath(@__DIR__, "wrappers", "\$(best_platform).jl"))
        end

        end  # module $(src_name)_jll
        """)
    end

    # Add a README.md
    open(joinpath(code_dir, "README.md"), "w") do io
        print(io, """
        # $(src_name)_jll.jl

        This is an autogenerated package constructed using [`BinaryBuilder.jl`](https://github.com/JuliaPackaging/BinaryBuilder.jl).

        ## Usage

        The code bindings within this package are autogenerated from the `Products` defined within the `build_tarballs.jl` file that generated this package.  For example purposes, we will assume that the following products were defined:

        ```julia
        products = [
            FileProduct("src/data.txt", :data_txt),
            LibraryProduct("libdataproc", :libdataproc),
            ExecutableProduct("mungify", :mungify_exe)
        ]
        ```

        With such products defined, this package will contain `data_txt`, `libdataproc` and `mungify_exe` symbols exported. For `FileProduct` variables, the exported value is a string pointing to the location of the file on-disk.  For `LibraryProduct` variables, it is a string corresponding to the `SONAME` of the desired library (it will have already been `dlopen()`'ed, so typical `ccall()` usage applies), and for `ExecutableProduct` variables, the exported value is a function that can be called to set appropriate environment variables.  Example:

        ```julia
        using $(src_name)_jll

        # For file products, you can access its file location directly:
        data_lines = open(data_txt, "r") do io
            readlines(io)
        end

        # For library products, you can use the exported variable name in `ccall()` invocations directly
        num_chars = ccall((libdataproc, :count_characters), Cint, (Cstring, Cint), data_lines[1], length(data_lines[1]))

        # For executable products, you can use the exported variable name as a function that you can call
        mungify_exe() do mungify_exe_path
            run(`\$mungify_exe_path \$num_chars`)
        end
        ```
        """)
    end

    # Add a Project.toml
    project = build_project_dict(src_name, build_version, dependencies)
    open(joinpath(code_dir, "Project.toml"), "w") do io
        Pkg.TOML.print(io, project)
    end
end

jll_uuid(name) = Pkg.Types.uuid5(Pkg.Types.uuid_package, "$(name)_jll")
function build_project_dict(name, version, dependencies)
    project = Dict(
        "name" => "$(name)_jll",
        "uuid" => string(jll_uuid("$(name)_jll")),
        "version" => string(version),
        "deps" => Dict{String,Any}(dep => string(jll_uuid(dep)) for dep in dependencies),
        # We require at least Julia 1.3+, for Pkg.Artifacts support
        "compat" => Dict{String,Any}("julia" => "1.3"),
    )
    # Always add Libdl and Pkg as dependencies
    project["deps"]["Libdl"] = first([string(u) for (u, n) in Pkg.Types.stdlib() if n == "Libdl"])
    project["deps"]["Pkg"] = first([string(u) for (u, n) in Pkg.Types.stdlib() if n == "Pkg"])

    return project
end
