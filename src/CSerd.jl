""" Low-level wrapper of C library Serd.
"""
module CSerd
export SerdException, SerdNode, SerdStatement, SerdStatementFlags, SerdStyles,
  SerdReader, serd_reader_new, serd_reader_free,
  serd_reader_set_error_sink, serd_reader_set_strict,
  serd_reader_add_blank_prefix, serd_reader_set_default_graph,
  serd_reader_read_file, serd_reader_read_string,
  SerdWriter, serd_writer_new, serd_writer_free,
  serd_writer_set_error_sink, serd_writer_chop_blank_prefix,
  serd_writer_set_base_uri, serd_writer_set_root_uri,
  serd_writer_set_prefix, serd_writer_write_statement, serd_writer_finish
  
# Reference to Serd library.
include("../deps/deps.jl")

import Base: close
using AutoHashEquals

""" Export an enum and all its values.
"""
macro export_enum(name::Symbol)
  expr = :(eval(Expr(:export, $(QuoteNode(name)), 
                     (Symbol(inst) for inst in instances($name))...)))
  esc(Expr(:toplevel, expr))
end

const Cbool = UInt8

# Data types
############

@enum(SerdStatus,
  SERD_SUCCESS,
  SERD_FAILURE,
  SERD_ERR_UNKNOWN,
  SERD_ERR_BAD_SYNTAX,
  SERD_ERR_BAD_ARG,
  SERD_ERR_NOT_FOUND,
  SERD_ERR_ID_CLASH,
  SERD_ERR_BAD_CURIE,
  SERD_ERR_INTERNAL)
@export_enum SerdStatus

@enum(SerdSyntax,
  SERD_TURTLE   = 1,  # Turtle - Terse RDF Triple Language
  SERD_NTRIPLES = 2,  # NTriples - Line-based RDF triples
  SERD_NQUADS   = 3,  # NQuads - Line-based RDF quads
  SERD_TRIG     = 4)  # TRiG - Terse RDF quads
@export_enum SerdSyntax

@enum(SerdStatementFlag,
  SERD_EMPTY_S      = 1 << 1,  # Empty blank node subject
  SERD_EMPTY_O      = 1 << 2,  # Empty blank node object
  SERD_ANON_S_BEGIN = 1 << 3,  # Start of anonymous subject
  SERD_ANON_O_BEGIN = 1 << 4,  # Start of anonymous object
  SERD_ANON_CONT    = 1 << 5,  # Continuation of anonymous node
  SERD_LIST_S_BEGIN = 1 << 6,  # Start of list subject
  SERD_LIST_O_BEGIN = 1 << 7,  # Start of list object
  SERD_LIST_CONT    = 1 << 8)  # Continuation of list
@export_enum SerdStatementFlag
const SerdStatementFlags = UInt32

@enum(SerdType,
  SERD_NOTHING = 0,  # The type of a nonexistent node.
  SERD_LITERAL = 1,  # Literal value
  SERD_URI     = 2,  # URI (absolute or relative)
  SERD_CURIE   = 3,  # CURIE, a shortened URI
  SERD_BLANK   = 4)  # A blank node
@export_enum SerdType

@enum(SerdStyle,
  SERD_STYLE_ABBREVIATED = 1,       # Abbreviate triples when possible
  SERD_STYLE_ASCII       = 1 << 1,  # Escape all non-ASCII characters
  SERD_STYLE_RESOLVED    = 1 << 2,  # Resolve URIs against base URI
  SERD_STYLE_CURIED      = 1 << 3,  # Shorten URIs into CURIEs
  SERD_STYLE_BULK        = 1 << 4)  # Write output in pages
@export_enum SerdStyle
const SerdStyles = UInt32

struct SerdException <: Exception
  status::SerdStatus
end

@auto_hash_equals struct SerdNode
  value::String
  typ::SerdType
end

@auto_hash_equals struct SerdStatement
  flags::SerdStatementFlags
  graph::Nullable{SerdNode}
  subject::SerdNode
  predicate::SerdNode
  object::SerdNode
  object_datatype::Nullable{SerdNode}
  object_lang::Nullable{SerdNode}
end

mutable struct SerdReader
  ptr::Ptr{Void}
  base_sink::Nullable{Function}
  prefix_sink::Nullable{Function}
  statement_sink::Nullable{Function}
  end_sink::Nullable{Function}
  error_sink::Nullable{Function}
end

mutable struct SerdWriter
  ptr::Ptr{Void}
  env::Ptr{Void}
  sink::Function
  error_sink::Nullable{Function}
end

struct CSerdNode
  buf::Ptr{UInt8}
  n_bytes::Csize_t
  n_chars::Csize_t
  flags::Cint
  typ::Cint
end

struct CSerdError
  status::Cint
  filename::Ptr{UInt8}
  line::Cuint
  col::Cuint
  char::Ptr{Cchar}
  args::Ptr{Void} # va_list *
end

# Node
######

""" Convert Serd node from Julia struct to C struct.
"""
function c_serd_node(node::SerdNode)::CSerdNode
  ccall((:serd_node_from_string, serd), CSerdNode, (Cint, Cstring),
        Cint(node.typ), node.value)
end
function c_serd_node(node::Nullable{SerdNode})::Ptr{CSerdNode}
  isnull(node) ? C_NULL : pointer_from_objref(c_serd_node(get(node)))
end

""" Convert Serd node from C struct to Julia struct.
"""
function unsafe_serd_node(ptr::Ptr{CSerdNode})::Nullable{SerdNode}
  if ptr == C_NULL
    Nullable{SerdNode}()
  else
    typ = unsafe_load(Ptr{Cint}(ptr + fieldoffset(CSerdNode,5)))
    if typ == SERD_NOTHING
      Nullable{SerdNode}()
    else
      n_bytes = unsafe_load(Ptr{Csize_t}(ptr + fieldoffset(CSerdNode,2)))
      value_ptr = unsafe_load(Ptr{Ptr{UInt8}}(ptr))
      value = unsafe_string(value_ptr, n_bytes)
      Nullable(SerdNode(value, SerdType(typ)))
    end
  end
end

serd_status(status) = Cint(isa(status, SerdStatus) ? status : SERD_SUCCESS)

function check_serd_status(status)
  status = SerdStatus(status)
  if status != SERD_SUCCESS
    throw(SerdException(status))
  end
end

# Reader
########

""" Create a new RDF reader.
"""
function serd_reader_new(syntax::SerdSyntax, base_sink, prefix_sink,
                         statement_sink, end_sink)::SerdReader
  serd_base_sink_ptr = cfunction(
    serd_base_sink, Cint, (Ptr{Void}, Ptr{CSerdNode}))
  serd_prefix_sink_ptr = cfunction(
    serd_prefix_sink, Cint, (Ptr{Void}, Ptr{CSerdNode}, Ptr{CSerdNode}))  
  serd_statement_sink_ptr = cfunction(
    serd_statement_sink,
    Cint,
    (Ptr{Void}, Cint, Ptr{CSerdNode}, Ptr{CSerdNode}, Ptr{CSerdNode},
     Ptr{CSerdNode}, Ptr{CSerdNode}, Ptr{CSerdNode}))
  serd_end_sink_ptr = cfunction(
    serd_end_sink, Cint, (Ptr{Void}, Ptr{CSerdNode}))
  
  reader = SerdReader(
    C_NULL, base_sink, prefix_sink, statement_sink, end_sink, nothing)
  reader.ptr = ccall(
    (:serd_reader_new, serd),
    Ptr{Void},
    (Cint, Any, Ptr{Void}, Ptr{Void}, Ptr{Void}, Ptr{Void}, Ptr{Void}),
    syntax, reader, C_NULL, serd_base_sink_ptr, serd_prefix_sink_ptr,
    serd_statement_sink_ptr, serd_end_sink_ptr)
  finalizer(reader, serd_reader_free)
  return reader
end
function serd_base_sink(handle::Ptr{Void}, uri::Ptr{CSerdNode})
  reader = unsafe_pointer_to_objref(handle)::SerdReader
  serd_status(if !isnull(reader.base_sink)
    get(reader.base_sink)(get(unsafe_serd_node(uri)))
  end)
end
function serd_prefix_sink(handle::Ptr{Void}, name::Ptr{CSerdNode}, uri::Ptr{CSerdNode})
  reader = unsafe_pointer_to_objref(handle)::SerdReader
  serd_status(if !isnull(reader.prefix_sink)
    get(reader.prefix_sink)(
      get(unsafe_serd_node(name)),
      get(unsafe_serd_node(uri)))
  end)
end
function serd_statement_sink(
    handle::Ptr{Void}, flags::Cint, graph::Ptr{CSerdNode},
    subject::Ptr{CSerdNode}, predicate::Ptr{CSerdNode}, object::Ptr{CSerdNode},
    object_datatype::Ptr{CSerdNode}, object_lang::Ptr{CSerdNode}
  )
  reader = unsafe_pointer_to_objref(handle)::SerdReader
  serd_status(if !isnull(reader.statement_sink)
    get(reader.statement_sink)(SerdStatement(
      flags,
      unsafe_serd_node(graph),
      get(unsafe_serd_node(subject)),
      get(unsafe_serd_node(predicate)),
      get(unsafe_serd_node(object)),
      unsafe_serd_node(object_datatype),
      unsafe_serd_node(object_lang)))
  end)
end
function serd_end_sink(handle::Ptr{Void}, node::Ptr{CSerdNode})
  reader = unsafe_pointer_to_objref(handle)::SerdReader
  serd_status(if !isnull(reader.end_sink)
    get(reader.end_sink)(get(unsafe_serd_node(node)))
  end)
end

""" Set a function to be called when errors occur during reading.

If no error function is set, errors are printed to stderr in GCC style.
"""
function serd_reader_set_error_sink(reader::SerdReader, error_sink)
  reader.error_sink = error_sink
  serd_error_sink_ptr = isnull(reader.error_sink) ? C_NULL :
    cfunction(serd_error_sink, Cint, (Ptr{Void}, Ptr{CSerdError}))
  ccall(
    (:serd_reader_set_error_sink, serd),
    Void,
    (Ptr{Void}, Ptr{Void}, Any),
    reader.ptr, serd_error_sink_ptr, reader)
end
function serd_error_sink(handle::Ptr{Void}, error::Ptr{CSerdError})
  obj = unsafe_pointer_to_objref(handle)::Union{SerdReader,SerdWriter}
  serd_status(if !isnull(obj.error_sink)
    # FIXME: Include error information besides status code.
    status = unsafe_load(Ptr{Cint}(error))
    get(obj.error_sink)(status)
  end)
end

""" Enable or disable strict parsing.

The reader is non-strict (lax) by default, which will tolerate URIs with
invalid characters. Setting strict will fail when parsing such files. An error
is printed for invalid input in either case.
"""
function serd_reader_set_strict(reader::SerdReader, strict::Bool)
  ccall((:serd_reader_set_strict, serd), Void, (Ptr{Void}, Cbool),
        reader.ptr, strict)
end

""" Set a prefix to be added to all blank node identifiers.

This is useful when multiple files are to be parsed into the same output
(e.g. a store, or other files). Since Serd preserves blank node IDs, this could
cause conflicts where two non-equivalent blank nodes are merged, resulting in
corrupt data. By setting a unique blank node prefix for each parsed file, this
can be avoided, while preserving blank node names.
"""
function serd_reader_add_blank_prefix(reader::SerdReader, prefix::String)
  ccall((:serd_reader_add_blank_prefix, serd), Void, (Ptr{Void}, Cstring),
        reader.ptr, prefix)
end

""" Set the URI of the default graph.

If this is set, the reader will emit quads with the graph set to the given node
for any statements that are not in a named graph.
"""
function serd_reader_set_default_graph(reader::SerdReader, graph::SerdNode)
  ccall((:serd_reader_set_default_graph, serd), Void, (Ptr{Void}, Ref{CSerdNode}),
        reader.ptr, c_serd_node(graph))
end

""" Read a file at a given URI.
"""
function serd_reader_read_file(reader::SerdReader, uri::String)
  check_serd_status(ccall(
    (:serd_reader_read_file, serd),
    Cint,
    (Ptr{Void}, Cstring),
    reader.ptr, uri
  ))
end

""" Read from UTF8 string.
"""
function serd_reader_read_string(reader::SerdReader, str::String)
  check_serd_status(ccall(
    (:serd_reader_read_string, serd),
    Cint,
    (Ptr{Void}, Cstring),
    reader.ptr, str
  ))
end

""" Free RDF reader. 

This function will be called automatically when the Julia Serd reader is
garbage collected.
"""
function serd_reader_free(reader::SerdReader)::Void
  if reader.ptr != C_NULL
    ccall((:serd_reader_free, serd), Void, (Ptr{Void},), reader.ptr)
    reader.ptr = C_NULL
  end
  nothing
end

# Writer
########

""" Create a new RDF writer.
"""
function serd_writer_new(syntax::SerdSyntax, style::SerdStyles, io::IO)::SerdWriter
  sink = text -> write(io, text)
  serd_writer_new(syntax, style, sink)
end
function serd_writer_new(syntax::SerdSyntax, style::SerdStyles, sink::Function)::SerdWriter
  serd_sink_ptr = cfunction(serd_writer_sink, Csize_t, (Ptr{Void}, Csize_t, Ptr{Void}))
  env_ptr = ccall((:serd_env_new, serd), Ptr{Void}, (Ptr{CSerdNode},), C_NULL)
  writer = SerdWriter(C_NULL, env_ptr, sink, nothing)
  writer.ptr = ccall(
    (:serd_writer_new, serd),
    Ptr{Void},
    (Cint, Cint, Ptr{Void}, Ptr{Void}, Ptr{Void}, Any),
    syntax, style, env_ptr, C_NULL, serd_sink_ptr, writer)
  finalizer(writer, serd_writer_free)
  return writer
end
function serd_writer_sink(buf::Ptr{Void}, len::Csize_t, handle::Ptr{Void})
  writer = unsafe_pointer_to_objref(handle)::SerdWriter
  writer.sink(unsafe_string(Ptr{UInt8}(buf), len))
  return len
end

""" Set a function to be called when errors occur during writing.

The error_sink will be called with handle as its first argument. If no error
function is set, errors are printed to stderr.
"""
function serd_writer_set_error_sink(writer::SerdWriter, error_sink)
  writer.error_sink = error_sink
  serd_error_sink_ptr = isnull(writer.error_sink) ? C_NULL :
    cfunction(serd_error_sink, Cint, (Ptr{Void}, Ptr{CSerdError}))
  ccall(
    (:serd_writer_set_error_sink, serd),
    Void,
    (Ptr{Void}, Ptr{Void}, Any),
    writer.ptr, serd_error_sink_ptr, writer)
end

""" Set a prefix to be removed from matching blank node identifiers.
"""
function serd_writer_chop_blank_prefix(writer::SerdWriter, prefix::String)
  ccall(
    (:serd_writer_chop_blank_prefix, serd),
    Void,
    (Ptr{Void}, Cstring),
    writer.ptr, prefix)
end

""" Set the current output base URI.
"""
function serd_writer_set_base_uri(writer::SerdWriter, uri::SerdNode)
  check_serd_status(ccall(
    (:serd_writer_set_base_uri, serd),
    Cint,
    (Ptr{Void}, Ref{CSerdNode}),
    writer.ptr, c_serd_node(uri)
  ))
end

""" Set the current root URI.

The root URI should be a prefix of the base URI. The path of the root URI is
the highest path any relative up-reference can refer to. 
"""
function serd_writer_set_root_uri(writer::SerdWriter, uri::SerdNode)
  check_serd_status(ccall(
    (:serd_writer_set_root_uri, serd),
    Cint,
    (Ptr{Void}, Ref{CSerdNode}),
    writer.ptr, c_serd_node(uri)
  ))
end

""" Set a namespace prefix.
"""
function serd_writer_set_prefix(writer::SerdWriter, name::SerdNode, uri::SerdNode)
  check_serd_status(ccall(
    (:serd_writer_set_prefix, serd),
    Cint,
    (Ptr{Void}, Ref{CSerdNode}, Ref{CSerdNode}),
    writer.ptr, c_serd_node(name), c_serd_node(uri)
  ))
end

""" Write a statement (RDF triple or quad).
"""
function serd_writer_write_statement(writer::SerdWriter, stmt::SerdStatement)
  check_serd_status(ccall(
    (:serd_writer_write_statement, serd),
    Cint,
    (Ptr{Void}, Cint, Ptr{CSerdNode}, Ref{CSerdNode}, Ref{CSerdNode},
     Ref{CSerdNode}, Ptr{CSerdNode}, Ptr{CSerdNode}),
    writer.ptr,
    stmt.flags,
    c_serd_node(stmt.graph),
    c_serd_node(stmt.subject),
    c_serd_node(stmt.predicate),
    c_serd_node(stmt.object),
    c_serd_node(stmt.object_datatype),
    c_serd_node(stmt.object_lang)
  ))
end

""" Mark the end of an anonymous node's description. 
"""
function serd_writer_end_anon(writer::SerdWriter, node::SerdNode)
  check_serd_status(ccall(
    (:serd_writer_end_anon, serd),
    Cint,
    (Ptr{Void}, Ref{CSerdNode}),
    writer.ptr, c_serd_node(node)
  ))
end

""" Finish a write.
"""
function serd_writer_finish(writer::SerdWriter)
  ccall((:serd_writer_finish, serd), Void, (Ptr{Void},), writer.ptr)
end
close(writer::SerdWriter) = serd_writer_finish(writer)

""" Free RDF writer. 

This function will be called automatically when the Julia Serd writer is
garbage collected.
"""
function serd_writer_free(writer::SerdWriter)::Void
  if writer.ptr != C_NULL
    ccall((:serd_writer_free, serd), Void, (Ptr{Void},), writer.ptr)
    writer.ptr = C_NULL
  end
  if writer.env != C_NULL
    ccall((:serd_env_free, serd), Void, (Ptr{Void},), writer.env)
    writer.env = C_NULL
  end
  nothing
end

end
