using .JS: @K_str, @KSet_str
using .JL: @ast

# initialization
# ==============

const NUMERIC_CHARACTERS = tuple(string.('0':'9')...)
const COMPLETION_TRIGGER_CHARACTERS = [
    "@",  # macro completion
    "\\", # LaTeX completion
    ":",  # emoji completion
    NUMERIC_CHARACTERS..., # allow these characters to be recognized by `CompletionContext.triggerCharacter`
]

completion_options() = CompletionOptions(;
    triggerCharacters = COMPLETION_TRIGGER_CHARACTERS,
    resolveProvider = true,
    completionItem = (;
        labelDetailsSupport = true))

const COMPLETION_REGISTRATION_ID = "jetls-completion"
const COMPLETION_REGISTRATION_METHOD = "textDocument/completion"

function completion_registration()
    (; triggerCharacters, resolveProvider, completionItem) = completion_options()
    return Registration(;
        id = COMPLETION_REGISTRATION_ID,
        method = COMPLETION_REGISTRATION_METHOD,
        registerOptions = CompletionRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
            triggerCharacters,
            resolveProvider,
            completionItem))
end

# For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id=COMPLETION_REGISTRATION_ID,
#     method=COMPLETION_REGISTRATION_METHOD))
# register(currently_running, completion_registration())

# completion utils
# ================

function completion_is(ci::CompletionItem, ckind::Symbol)
    # `ckind` is :global, :local, :argument, or :sparam.  Implementation likely
    # to change with changes to the information we put in CompletionItem.
    labelDetails = ci.labelDetails
    @assert labelDetails !== nothing
    return (labelDetails.description === String(ckind) ||
        (labelDetails.description === "argument" && ckind === :local))
end

# TODO use `let` block when Revise can handle it...
const sort_texts, max_sort_text = let
    sort_texts = Dict{Int, String}()
    for i = 1:1000
        sort_texts[i] = lpad(i, 4, '0')
    end
    _, max_sort_text = maximum(sort_texts)
    sort_texts, max_sort_text
end
function get_sort_text(offset::Int, isglobal::Bool)
    if isglobal
        return max_sort_text
    end
    return get(sort_texts, offset, max_sort_text)
end

# local completions
# =================

"""
    greatest_local(st0, b) -> (st::Union{SyntaxTree, Nothing}, b::Int)

Return the largest tree that can introduce local bindings that are visible to
the cursor (if any such tree exists), and the cursor's position within it.
"""
function greatest_local(st0::JL.SyntaxTree, b::Int)
    bas = byte_ancestors(st0, b)

    first_global = findfirst(st -> JL.kind(st) in KSet"toplevel module", bas)
    @assert !isnothing(first_global)
    if first_global === 1
        return (nothing, b)
    end

    i = first_global - 1
    while JL.kind(bas[i]) === K"block"
        # bas[i] is a block within a global scope, so can't introduce local
        # bindings.  Shrink the tree (mostly for performance).
        i -= 1
        i < 1 && return (nothing, b)
    end

    return bas[i], (b - (JS.first_byte(st0) - 1))
end

"""
Heuristic for showing completions.  A binding is relevant when all are true:
- it isn't generated by the compiler
- if nonglobal, it's defined before the cursor
- (if global) it doesn't contain or immediately precede the cursor
"""
function is_relevant(ctx::JL.AbstractLoweringContext,
                     binding::JL.BindingInfo,
                     cursor::Int)
    (;start, stop) = JS.byte_range(JL.binding_ex(ctx, binding.id))
    !binding.is_internal &&
        !in(cursor, (start+1):(stop+1)) &&
        (binding.kind === :global
         # || we could relax this for locals defined before the end of the
         #    largest for/while containing the cursor
         || cursor > start)
end

# TODO: Macro expansion requires we know the module we're lowering in, and that
# JuliaLowering sees the macro definition.  Ignore them in local completions for now.
function remove_macrocalls(st0::JL.SyntaxTree)
    ctx = JL.MacroExpansionContext(JL.syntax_graph(st0), JL.Bindings(),
                                   JL.ScopeLayer[], JL.ScopeLayer(1, Module(), false))
    if kind(st0) === K"macrocall"
        macroname = st0[1]
        if hasproperty(macroname, :name_val) && macroname.name_val == "@nospecialize"
            st0
        else
            @ast ctx st0 "nothing"::K"core"
        end
    elseif JS.is_leaf(st0)
        st0
    else
        k = kind(st0)
        @ast ctx st0 [k (map(remove_macrocalls, JS.children(st0)))...]
    end
end

let lowering_module = Module()
    global function jl_lower_for_completion(st0)
        ctx1, st1 = JL.expand_forms_1(lowering_module, remove_macrocalls(st0));
        ctx2, st2 = JL.expand_forms_2(ctx1, st1);
        ctx3, st3 = JL.resolve_scopes(ctx2, st2);
        return ctx3, st2
    end
end

"""
Find the list of (BindingInfo, SyntaxTree, distance::Int) to suggest as
completions given a parsed SyntaxTree and a cursor position.

JuliaLowering throws away the mapping from scopes to bindings (scopes are stored
as an ephemeral stack.)  We work around this by taking all available bindings
and filtering out any that aren't declared in a scope containing the cursor.
"""
function cursor_bindings(st0_top::JL.SyntaxTree, b_top::Int)
    st0, b = greatest_local(st0_top, b_top)
    if isnothing(st0)
        return nothing # nothing we can lower
    end
    ctx3, st2 = try
        jl_lower_for_completion(st0)
    catch err
        JETLS_DEV_MODE && @warn "Error in lowering" err
        return nothing # lowering failed, e.g. because of incomplete input
    end

    # Note that ctx.bindings are only available after resolve_scopes, and
    # scope-blocks are not present in st3 after resolve_scopes.
    binfos = filter(binfo -> is_relevant(ctx3, binfo, b), ctx3.bindings.info)

    # for each binding: binfo, all syntaxtrees containing it, and the scope it belongs to
    bscopeinfos = Tuple{JL.BindingInfo, JL.SyntaxList, Union{JL.SyntaxTree, Nothing}}[]
    for binfo in binfos
        # TODO: find tree parents instead of byte parents?
        bas = byte_ancestors(st2, JS.byte_range(JL.binding_ex(ctx3, binfo.id)))
        # find the innermost hard scope containing this binding decl.  we shouldn't
        # be in multiple overlapping scopes that are not direct ancestors; that
        # should indicate a provenance failure
        i = findfirst(ba -> JS.kind(ba) in KSet"scope_block lambda module toplevel", bas)
        push!(bscopeinfos, (binfo, bas, isnothing(i) ? nothing : bas[i]))
    end

    cursor_scopes = byte_ancestors(st2, b)

    # ignore scopes we aren't in
    filter!(((binfo, _, bs),) -> isnothing(bs) || bs._id in cursor_scopes.ids,
            bscopeinfos)

    # Now eliminate duplicates by name.
    # - Prefer any local binding belonging to a tighter scope (lower bdistance)
    # - If a static parameter and a local of the same name exist in the same
    #   scope (impossible in julia), the local is internal and should be ignored
    bdistances = map(((_, _, bs),) -> if isnothing(bs)
                         lastindex(cursor_scopes.ids) + 1
                     else
                         findfirst(cs -> bs._id === cs, cursor_scopes.ids)
                     end,
                     bscopeinfos)

    seen = Dict{String, Int}()
    for i in eachindex(bscopeinfos)
        (binfo, _, _) = bscopeinfos[i]

        prev = get(seen, binfo.name, nothing)
        if (isnothing(prev)
            || bdistances[i] < bdistances[prev]
            || binfo.kind === :static_parameter)
            seen[binfo.name] = i
        elseif JETLS_DEV_MODE
            @info "Found two bindings with the same name:" binfo bscopeinfos[prev][1]
        end
    end

    return map(values(seen)) do i
        (binfo, _, _) = bscopeinfos[i]
        # distance from the cursor
        dist = abs(b - JS.last_byte(JL.binding_ex(ctx3, binfo.id)))
        return (binfo, JL.binding_ex(ctx3, binfo.id), dist)
    end
end

"""
# Typical completion UI

to|
   ┌───┬──────────────────────────┬────────────────────────────┐
   │(1)│to_completion(2)     (3) >│(4)...                      │
   │(1)│to_indices(2)        (3)  │# Typical completion UI ─(5)│
   │(1)│touch(2)             (3)  │                          │ │
   └───┴──────────────────────────┤to|                       │ │
                                  │...                     ──┘ │
                                  └────────────────────────────┘
(1) Icon corresponding to CompletionItem's `ci.kind`
(2) `ci.labelDetails.detail`
(3) `ci.labelDetails.description`
(4) `ci.detail` (possibly at (3))
(5) `ci.documentation`

Sending (4) and (5) to the client can happen eagerly in response to <TAB>
(textDocument/completion), or lazily, on selection in the list
(completionItem/resolve).  The LSP specification notes that more can be deferred
in later versions.
"""
function to_completion(binding::JL.BindingInfo,
                       st::JL.SyntaxTree,
                       sort_offset::Int=0)
    label_kind = CompletionItemKind.Variable
    label_detail = nothing
    label_desc = nothing
    documentation = nothing

    if binding.is_const
        label_kind = CompletionItemKind.Constant
    elseif binding.kind === :static_parameter
        label_kind = CompletionItemKind.TypeParameter
    end

    if binding.kind in [:argument, :local, :global]
        label_desc = String(binding.kind)
    elseif binding.kind === :static_parameter
        label_desc = "sparam"
    end

    if !isnothing(binding.type)
        label_detail = "::" * JL.sourcetext(binding.type)
    end

    documentation = MarkupContent(;
        kind = MarkupKind.Markdown,
        value = "```julia\n" * sprint(JL.showprov, st) * "\n```")

    CompletionItem(;
        label = binding.name,
        labelDetails = CompletionItemLabelDetails(;
            detail = label_detail,
            description = label_desc),
        kind = label_kind,
        documentation,
        sortText = get_sort_text(sort_offset, #=isglobal=#false),
        data = CompletionData(#=needs_resolve=#false))
end

function local_completions!(items::Dict{String, CompletionItem},
                            s::ServerState, uri::URI, params::CompletionParams)
    let context = params.context
        !isnothing(context) &&
            # Don't trigger completion just by typing a numeric character:
            context.triggerCharacter in NUMERIC_CHARACTERS && return nothing
    end
    fi = get_fileinfo(s, uri)
    fi === nothing && return nothing
    # NOTE don't bail out even if `length(fi.parsed_stream.diagnostics) ≠ 0`
    # so that we can get some completions even for incomplete code
    st0 = JS.build_tree(JL.SyntaxTree, fi.parsed_stream)
    cbs = cursor_bindings(st0, xy_to_offset(fi, params.position))
    cbs === nothing && return nothing
    for (bi, st, dist) in cbs
        ci = to_completion(bi, st, dist)
        prev_ci = get(items, ci.label, nothing)
        # Name collisions: overrule existing global completions with our own,
        # unless our completion is also a global, in which case the existing
        # completion from JET will have more information.
        if isnothing(prev_ci) || (completion_is(prev_ci, :global) && !completion_is(ci, :global))
            items[ci.label] = ci
        end
    end
    return items
end

# global completions
# ==================

function global_completions!(items::Dict{String, CompletionItem}, state::ServerState, uri::URI, params::CompletionParams)
    let context = params.context
        !isnothing(context) &&
            # Don't trigger completion just by typing a numeric character:
            context.triggerCharacter in NUMERIC_CHARACTERS && return nothing
    end
    pos = params.position
    fi = get_fileinfo(state, uri)
    fi === nothing && return nothing
    mod = find_file_module!(state, uri, pos)
    current_token_idx = get_current_token_idx(fi, pos)
    current_token = fi.parsed_stream.tokens[current_token_idx]
    current_kind = JS.kind(current_token)

    # Case: `@│`
    if current_kind === JS.K"@"
        edit_start_pos = offset_to_xy(fi, fi.parsed_stream.tokens[current_token_idx - 1].next_byte)
        is_macro_invoke = true
    # Case: `@macr│`
    elseif current_kind === JS.K"MacroName"
        edit_start_pos = offset_to_xy(fi, fi.parsed_stream.tokens[current_token_idx - 2].next_byte)
        is_macro_invoke = true
    # Case `│` (empty program)
    elseif current_kind === JS.K"TOMBSTONE"
        edit_start_pos = Position(; line=0, character=0)
        is_macro_invoke = false
    else
        edit_start_pos = offset_to_xy(fi, fi.parsed_stream.tokens[current_token_idx - 1].next_byte)
        is_macro_invoke = false
    end

    for name in @invokelatest(names(mod; all=true, imported=true, usings=true))::Vector{Symbol}
        s = String(name)
        startswith(s, "#") && continue

        if is_macro_invoke && !startswith(s, "@")
            # If we are in a macro invocation context, we only want to complete macros.
            # Conversely, we allow macros to be completed in any context.
            continue
        end

        items[s] = CompletionItem(;
            label = s,
            labelDetails = CompletionItemLabelDetails(;
                description = startswith(s, "@") ? "macro" : "global"),
            kind = CompletionItemKind.Variable,
            documentation = nothing,
            sortText = get_sort_text(0, #=isglobal=#true),
            data = CompletionData(#=needs_resolve=#true),
            textEdit = TextEdit(;
                range = Range(;
                    start = edit_start_pos,
                    var"end" = pos),
                newText = s))
    end
    # if we are in macro name context, then we don't need any local completions
    # as macros are always defined top-level
    return is_macro_invoke ? items : nothing # is_completed
end

# LaTeX and emoji completions
# ===========================

"""
    get_backslash_offset(state::ServerState, fi::FileInfo, pos::Position) -> offset::Int, is_emoji::Bool

Get the byte `offset` of a backslash if the token immediately before the cursor
consists of a backslash and colon.
`is_emoji` indicates that a backslash is followed by the emoji completion trigger (`:`).
Returns `nothing` if such a token does not exist or if another token appears
immediately before the cursor.

Examples:
1. `\\┃ beta`       returns byte offset of `\\` and `false`
2. `\\alph┃`        returns byte offset of `\\` and `false`
3. `\\  ┃`          returns `nothing` (whitespace before cursor)
4. `\\:┃`           returns byte offset of `\\` and `true`
5. `\\:smile┃       returns byte offset of `\\` and `true`
6. `\\:+1┃          returns byte offset of `\\` and `true`
7. `alpha┃`         returns `nothing`  (no backslash before cursor)
8. `\\alpha  bet┃a` returns `nothing` (no backslash immediately before token with cursor)
"""
function get_backslash_offset(state::ServerState, fi::FileInfo, pos::Position)
    tokens = fi.parsed_stream.tokens
    curr_idx = get_current_token_idx(fi, pos)

    if tokens[curr_idx].orig_kind == JS.K"\\"
        # case 1
        return tokens[curr_idx].next_byte - 1, false
    elseif curr_idx > 1 && checkbounds(Bool, tokens, curr_idx-1) && tokens[curr_idx-1].orig_kind == JS.K"\\"
        if tokens[curr_idx].orig_kind == JS.K"Whitespace"
            return nothing # case 3
        else
            # Check if current token is colon (emoji pattern)
            if tokens[curr_idx].orig_kind == JS.K":"
                # case 4 & case 5
                return tokens[curr_idx-1].next_byte - 1, true
            else
                return tokens[curr_idx-1].next_byte - 1, false
            end
        end
    elseif curr_idx > 2
        # Search backwards for \: pattern
        i = curr_idx - 1
        while i >= 2
            token = tokens[i]
            token1 = tokens[i-1]
            if token1.orig_kind == JS.K"\\" && token.orig_kind == JS.K":"
                # case 6
                return token1.next_byte - 1, true
            end
            # Stop searching if we hit whitespace
            if token.orig_kind == JS.K"Whitespace" || token.orig_kind == JS.K"NewlineWs"
                break
            end
            i -= 1
        end
    end
    return nothing # case 7, 8
end

# Add LaTeX and emoji completions to the items dictionary and return boolean indicating
# whether any completions were added.
function add_emoji_latex_completions!(items::Dict{String,CompletionItem}, state::ServerState, uri::URI, params::CompletionParams)
    fi = get_fileinfo(state, uri)
    fi === nothing && return nothing

    pos = params.position
    backslash_offset_emojionly = get_backslash_offset(state, fi, pos)
    backslash_offset_emojionly === nothing && return nothing
    backslash_offset, emojionly = backslash_offset_emojionly
    backslash_pos = offset_to_xy(fi, backslash_offset)

    function create_ci(key, val, is_emoji::Bool)
        sortText = label = lstrip(key, '\\')
        if is_emoji
            sortText = rstrip(lstrip(sortText, ':'), ':')
        end
        description = is_emoji ? "emoji" : "latex-symbol"
        return CompletionItem(;
            label,
            labelDetails=CompletionItemLabelDetails(;
                description),
            kind=CompletionItemKind.Snippet,
            documentation=val,
            sortText,
            filterText = key,
            textEdit=TextEdit(;
                range = Range(;
                    start = backslash_pos,
                    var"end" = pos),
                newText = val),
            data=CompletionData(false)
        )
    end

    emojionly || foreach(REPL.REPLCompletions.latex_symbols) do (key, val)
        items[key] = create_ci(key, val, false)
    end
    foreach(REPL.REPLCompletions.emoji_symbols) do (key, val)
        items[key] = create_ci(key, val, true)
    end

    # if we reached here, we have added all emoji and latex completions
    return items
end

# completion resolver
# ===================

function resolve_completion_item(state::ServerState, item::CompletionItem)
    isdefined(state, :completion_module) || return item
    data = item.data
    data isa CompletionData || return item
    data.needs_resolve || return item
    mod = state.completion_module
    name = Symbol(item.label)
    binding = Base.Docs.Binding(mod, name)
    docs = Base.Docs.doc(binding)
    return CompletionItem(;
        label = item.label,
        labelDetails = item.labelDetails,
        kind = item.kind,
        detail = item.detail,
        sortText = item.sortText,
        textEdit = item.textEdit,
        documentation = MarkupContent(;
            kind = MarkupKind.Markdown,
            value = string(docs)))
end

# request handler
# ===============

function get_completion_items(state::ServerState, uri::URI, params::CompletionParams)
    items = Dict{String, CompletionItem}()
    # order matters; see local_completions!
    return collect(values(@something(
        add_emoji_latex_completions!(items, state, uri, params),
        global_completions!(items, state, uri, params),
        local_completions!(items, state, uri, params),
        items)))
end

function handle_CompletionRequest(server::Server, msg::CompletionRequest)
    uri = msg.params.textDocument.uri
    items = get_completion_items(server.state, uri, msg.params)
    return send(server,
        ResponseMessage(;
            id = msg.id,
            result = CompletionList(;
                isIncomplete = false,
                items)))
end

function handle_CompletionResolveRequest(server::Server, msg::CompletionResolveRequest)
    return send(server,
        ResponseMessage(;
            id = msg.id,
            result = resolve_completion_item(server.state, msg.params)))
end
