using Chain
using Markdown
using GLMakie
using FileIO
using ImageTransformations
using Colors
using Pkg

############################ Initialization ##############################

include("colormap_generation.jl")

# Pause renderloop for slow software rendering.
# This way, we only render if we actualy save e.g. an image
GLMakie.set_window_config!(;
    framerate = 1.0,
    pause_rendering = true
)

# copy NEWS file over to documentation
cp(
    joinpath(@__DIR__, "..", "NEWS.md"),
    joinpath(@__DIR__, "documentation", "news.md"),
    force = true)

############################ Functions ##############################

function hfun_doc(params)
    fname = params[1]
    html_docstring(fname)
end

using Makie

function html_docstring(fname)
    doc = Base.doc(getfield(Makie, Symbol(fname)))
    body = Markdown.html(doc)

    # body = fd2html(replace(txt, raw"$" => raw"\$"), internal = true)

    return """
    <div class="docstring">
    <div class="doc-header" id="$fname">
    <a href="#$fname">$fname</a>
    </div>
    <div class="doc-content">$body</div>
    </div>
    """
end

hfun_api_reference() = join(map(html_docstring, names(Makie)))

function env_showhtml(com, _)
    content = Franklin.content(com)
    lang, ex_name, code = Franklin.parse_fenced_block(content, false)
    name = "example_$(hash(code))"
    str = """
    ```julia:$name
    __result = begin # hide
        $code
    end # hide
    println("~~~") # hide
    show(stdout, MIME"text/html"(), __result) # hide
    println("~~~") # hide
    nothing # hide
    ```
    \\textoutput{$name}
    """
    return str
end

function env_examplefigure(com, _)
    content = Franklin.content(com)
    lang, ex_name, code = Franklin.parse_fenced_block(content, false)
    if lang != "julia"
        error("Code block needs to be julia. Found: $(lang), $(typeof(lang))")
    end

    kwargs = eval(Meta.parse("Dict(pairs((;" * Franklin.content(com.braces[1]) * ")))"))

    name = get(kwargs, :name, "example_" * string(hash(content)))
    svg = get(kwargs, :svg, false)

    pngfile = "$name.png"
    svgfile = "$name.svg"

    # add the generated png name to the list of examples for this page, which
    # can later be used to assemble an overview page
    # for some reason franklin needs a pair as the content?
    pngsvec, _ = get!(Franklin.LOCAL_VARS, "examplefigures_png", String[] => Vector{String})
    push!(pngsvec, pngfile)

    str = """
    ```julia:example_figure
    __result = begin # hide
        $code
    end # hide
    save(joinpath(@OUTPUT, "$pngfile"), __result) # hide
    $(svg ? "save(joinpath(@OUTPUT, \"$svgfile\"), __result) # hide" : "")
    nothing # hide
    ```
    ~~~
    <a id="$name">
    ~~~
    \\fig{$name.$(svg ? "svg" : "png")}
    ~~~
    </a>
    ~~~
    """
    return str
end

# \video{name [, autoplay = false, loop = true, controls = true]}
function lx_video(lxc, _)
    params = split(Franklin.stent(lxc.braces[1]), ",", limit = 2)
    rpath, kwstring = params[1], length(params) == 1 ? "" : params[2]
    alt = ""

    param_namedtuple = eval(Meta.parse("(;" * kwstring * ")"))

    path  = Franklin.parse_rpath(rpath; canonical=false, code=true)
    fdir, fext = splitext(path)

    # there are several cases
    # A. a path with no extension --> guess extension
    # B. a path with extension --> use that
    # then in both cases there can be a relative path set but the user may mean
    # that it's in the subfolder /output/ (if generated by code) so should look
    # both in the relpath and if not found and if /output/ not already last dir
    candext = ifelse(isempty(fext),
    (".mp4", ".mkv", ".mov"), (fext,))
    for ext ∈ candext
        candpath = fdir * ext
        syspath  = joinpath(Franklin.PATHS[:site], split(candpath, '/')...)
        isfile(syspath) && return html_video(candpath, alt; param_namedtuple...)
    end
    # now try in the output dir just in case (provided we weren't already
    # looking there)
    p1, p2 = splitdir(fdir)
    if splitdir(p1)[2] != "output"
        for ext ∈ candext
            candpath = joinpath(p1, "output", p2 * ext)
            syspath  = joinpath(Franklin.PATHS[:site], split(candpath, '/')...)
            isfile(syspath) && return html_video(candpath, alt; param_namedtuple...)
        end
    end
    return Franklin.html_err("Video matching '$path' not found.")
end

function html_video(path, alt; controls::Bool = true, loop::Bool = true, autoplay::Bool = false)
    """
    ~~~
    <video src="$path" $(controls ? "controls" : "") $(loop ? "loop" : "") $(autoplay ? "autoplay muted playsinline" : "")></video>
    ~~~
    """
end


@delay function hfun_list_folder_with_images(params)

    file_location = locvar("fd_rpath")
    pathparts = split(file_location, r"\\|/")
    folder = joinpath(pathparts[1:end-1]..., only(params))

    mds = @chain begin
        readdir(joinpath(@__DIR__, folder))
        filter(endswith(".md"), _)
        filter(!=("index.md"), _)
    end

    divs = map(mds) do page
        name = splitext(page)[1]

        title = pagevar(joinpath(folder, page), "title")

        outputpath = joinpath(@__DIR__, "__site", "assets",
        folder, name, "code", "output")

        !isdir(outputpath) && return ""

        # retrieve the ordered list of generated pngs written by `env_examplefigure`
        pngpaths = pagevar(
            joinpath(folder, name),
            "examplefigures_png",
            default = String[]
        )

        filter!(pngpaths) do p
            if isfile(joinpath(outputpath, p))
                true
            else
                @warn "File $p from the list of example images for site \"$name\" was not found, it probably wasn't generated correctly."
                false
            end
        end

        thumb_height = 350

        thumbpaths = map(pngpaths) do p
            thumbpath = joinpath(outputpath, splitext(p)[1] * "_thumb.png")

            if !isfile(thumbpath)
                img = load(joinpath(outputpath, p))
                sz = size(img)
                # height is dim 1
                new_size = round.(Int, sz .÷ (sz[1] / thumb_height))
                img_resized = imresize(RGB{Float32}.(img), new_size,
                method=ImageTransformations.Interpolations.Lanczos4OpenCV())
                img_clamped = mapc.(x -> clamp(x, 0, 1), img_resized)
                save(thumbpath, img_clamped)
            end

            return thumbpath
        end

        thumbpaths_website = "/assets/$folder/$name/code/output/" .* basename.(thumbpaths)
        thumbs = map(thumbpaths_website, pngpaths) do thumbpath, pngpath
            bn = splitext(basename(pngpath))[1]
            return "<a href=\"$name#$bn\"><img class='plotting-function-thumb' src=\"$thumbpath\"/></a>"
        end

        """

        <div class="plotting-functions-item">
        <a href="$name"><h2>$title</h2></a>
        <div class="plotting-functions-thumbcontainer">
        $(join(thumbs))
        </div>
        </div>
        """
    end

    return "<div class=\"plotting-functions-grid\">$(join(divs))</div>"
end


@delay function hfun_list_folder(params)

    file_location = locvar("fd_rpath")
    pathparts = split(file_location, r"\\|/")
    folder = joinpath(pathparts[1:end-1]..., only(params))

    mds = @chain begin
        readdir(joinpath(@__DIR__, folder))
        filter(endswith(".md"), _)
        filter(!=("index.md"), _)
    end

    titles = map(mds) do md
        p = joinpath(folder, md)
        t = pagevar(p, "title")::String
    end

    title_links = map(mds, titles) do page, title
        name = splitext(page)[1]
        return """<a href="$name"><li>$title</li></a>"""
    end

    return "<ul>" * join(title_links) * "</ul>"
end


function hfun_colorschemes()
    return sprint() do md
        write(md, """
        <h2>misc</h2>
        <p>These colorschemes are not defined or provide different colors in ColorSchemes.jl
        They are kept for compatibility with the old behaviour of Makie, before v0.10.</p>
        """)

        write(
            md,
            generate_colorschemes_table(
            [:default; sort(collect(keys(PlotUtils.MISC_COLORSCHEMES)))]
            )
        )

        write(md, "<p>The following colorschemes are defined by ColorSchemes.jl.</p>")

        for cs in ["cmocean", "scientific", "matplotlib", "colorbrewer", "gnuplot", "colorcet", "seaborn", "general"]
            ks = sort([k for (k, v) in PlotUtils.ColorSchemes.colorschemes if occursin(cs, v.category)])
            write(md, "<h2>$cs</h2>")
            write(md, generate_colorschemes_table(ks))
        end
    end
end

function lx_outputimage(lxc, _)
    rpath = Franklin.stent(lxc.braces[1])
    path = Franklin.parse_rpath("output/" * rpath; canonical=false, code=true)
    return "![$rpath]($path)"
end

function hfun_generating_versions()

    function dep_version(depname)
        deps = Pkg.dependencies()
        version = first(d for d in deps if d.second.name == depname).second.version

        "$depname: v$version"
    end
    packages = ["Makie", "GLMakie", "CairoMakie", "WGLMakie"]
    return string(
        "<p>These docs were autogenerated using ",
        join([dep_version(x) for x in packages], ", "),
        "</p>")
end

function hfun_sidebar()
    items = join("""<li><a href="#$key">$(val[1])</a></li>""" for (key, val) in Franklin.PAGE_HEADERS)

    return "<ul class=\"sidebar\">$items</ul>"
end

struct NavEntry
    name::String
    children::Vector{NavEntry}
    metadata::Dict
end

@delay function hfun_navigation()
    all_pages = sort!(collect(keys(Franklin.ALL_PAGE_VARS)))

    naventries = NavEntry[]

    for page in all_pages
        parts = splitpath(page)

        this_page_vars = Franklin.ALL_PAGE_VARS[page]

        hidden = first(get(this_page_vars, "hidden", false => nothing))
        hidden && continue

        d = naventries
        for (j, part) in enumerate(parts)
            i = findfirst(x -> x.name == part, d)
            if i === nothing
                n = NavEntry(part, [], Dict())

                push!(d, n)
            else
                n = d[i]
            end
            d = n.children


            if j == length(parts)
                n.metadata["title"] = first(get(this_page_vars, "title", "" => nothing))
                n.metadata["order"] = first(get(this_page_vars, "order", 999 => nothing))
                n.metadata["icon"] = first(get(this_page_vars, "icon", "" => nothing))
                n.metadata["page"] = page === "index" ? "" : page

                pretty_url = match(r"(.*)/index.html", first(Franklin.LOCAL_VARS["fd_url"]))
                pretty_url = pretty_url === nothing ? nothing : pretty_url[1]

                n.metadata["isactive"] = pretty_url == n.metadata["page"] || pretty_url == "/" * join(parts, "/")
            end
        end
    end

    function should_collapse(naventry)
        !get(naventry.metadata, "isactive", false) && all(should_collapse, naventry.children)
    end

    function navsort!(entries)
        sort!(entries, by = e -> get(e.metadata, "order", Inf))
        foreach(entries) do entry
            navsort!(entry.children)
        end
    end

    navsort!(naventries)

    function printlist(io, naventries, level = "")
        isempty(naventries) && return

        print(io, "<ul>")

        for (i, naventry) in enumerate(naventries)

            this_level = join([level, string(i)], "-")

            has_children = !isempty(naventry.children)

            print(io, "<li>")

            active = get(naventry.metadata, "isactive", false)

            inputid = "menuitem$this_level"
            if has_children
                print(io, """<input class="collapse-toggle" id="$inputid" type="checkbox" $(should_collapse(naventry) ? "" : "checked")>""")
            end

            print(io, """<div class="tocitem-container">""")

            if has_children
                print(io, """<label class="tocexpander" for="$inputid">""")
                print(io, "<i class=\"docs-chevron\"></i>")
                print(io, "</label>")
            end

            if haskey(naventry.metadata, "page")
                print(io, """<a $(active ? "class = active" : "") href="/$(naventry.metadata["page"])">$(naventry.metadata["title"])</a>""")
            else
                print(io, """<span $(active ? "class = active" : "")>$(get(naventry.metadata, "title", ""))</span>""")
            end

            print(io, "</div>")

            if active
                print(io, contenttable())
            end

            printlist(io, naventry.children, this_level)
            print(io, "</li>\n")
        end
        print(io, "</ul>")
    end

    return sprint(io-> printlist(io, naventries))
end


function contenttable()
    isempty(Franklin.PAGE_HEADERS) && return ""

    return sprint() do io

        println(io, """<ul class="page-content">""")

        order_stack = [first(Franklin.PAGE_HEADERS)[2][3]]

        for (key, val) in Franklin.PAGE_HEADERS
            order = val[3]

            n_steps_up = count(>=(order), order_stack)

            if n_steps_up == 0
                println(io, "<li><ul>")
            elseif n_steps_up == 1
                # do nothing
            else
                for i in 2:n_steps_up
                    println(io, "</ul></li>")
                end
            end
            filter!(<(order), order_stack)
            push!(order_stack, order)

            println(io, "<li><a href=\"#$key\">$(val[1])</a></li>")
        end

        for i in 1:length(order_stack)
            println(io, "</ul>")
        end
    end
end
