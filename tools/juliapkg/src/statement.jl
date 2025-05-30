mutable struct Stmt <: DBInterface.Statement
    con::Connection
    handle::duckdb_prepared_statement
    sql::AbstractString
    result_type::Type

    function Stmt(con::Connection, sql::AbstractString, result_type::Type)
        handle = Ref{duckdb_prepared_statement}()
        result = duckdb_prepare(con.handle, sql, handle)
        if result != DuckDBSuccess
            ptr = duckdb_prepare_error(handle[])
            if ptr == C_NULL
                error_message = "Preparation of statement failed: unknown error"
            else
                error_message = unsafe_string(ptr)
            end
            duckdb_destroy_prepare(handle)
            throw(QueryException(error_message))
        end
        stmt = new(con, handle[], sql, result_type)
        finalizer(_close_stmt, stmt)
        return stmt
    end

    function Stmt(db::DB, sql::AbstractString, result_type::Type)
        return Stmt(db.main_connection, sql, result_type)
    end
end

function _close_stmt(stmt::Stmt)
    if stmt.handle != C_NULL
        duckdb_destroy_prepare(stmt.handle)
    end
    stmt.handle = C_NULL
    return
end

DBInterface.getconnection(stmt::Stmt) = stmt.con


function nparameters(stmt::Stmt)
    return Int(duckdb_nparams(stmt.handle))
end


duckdb_bind_internal(stmt::Stmt, i::Integer, val::AbstractFloat) = duckdb_bind_double(stmt.handle, i, Float64(val));
duckdb_bind_internal(stmt::Stmt, i::Integer, val::Bool) = duckdb_bind_boolean(stmt.handle, i, val);
duckdb_bind_internal(stmt::Stmt, i::Integer, val::Int8) = duckdb_bind_int8(stmt.handle, i, val);
duckdb_bind_internal(stmt::Stmt, i::Integer, val::Int16) = duckdb_bind_int16(stmt.handle, i, val);
duckdb_bind_internal(stmt::Stmt, i::Integer, val::Int32) = duckdb_bind_int32(stmt.handle, i, val);
duckdb_bind_internal(stmt::Stmt, i::Integer, val::Int64) = duckdb_bind_int64(stmt.handle, i, val);
duckdb_bind_internal(stmt::Stmt, i::Integer, val::UInt8) = duckdb_bind_uint8(stmt.handle, i, val);
duckdb_bind_internal(stmt::Stmt, i::Integer, val::UInt16) = duckdb_bind_uint16(stmt.handle, i, val);
duckdb_bind_internal(stmt::Stmt, i::Integer, val::UInt32) = duckdb_bind_uint32(stmt.handle, i, val);
duckdb_bind_internal(stmt::Stmt, i::Integer, val::UInt64) = duckdb_bind_uint64(stmt.handle, i, val);
duckdb_bind_internal(stmt::Stmt, i::Integer, val::Float32) = duckdb_bind_float(stmt.handle, i, val);
duckdb_bind_internal(stmt::Stmt, i::Integer, val::Float64) = duckdb_bind_double(stmt.handle, i, val);
duckdb_bind_internal(stmt::Stmt, i::Integer, val::Date) = duckdb_bind_date(stmt.handle, i, value_to_duckdb(val));
duckdb_bind_internal(stmt::Stmt, i::Integer, val::Time) = duckdb_bind_time(stmt.handle, i, value_to_duckdb(val));
duckdb_bind_internal(stmt::Stmt, i::Integer, val::DateTime) =
    duckdb_bind_timestamp(stmt.handle, i, value_to_duckdb(val));
duckdb_bind_internal(stmt::Stmt, i::Integer, val::Missing) = duckdb_bind_null(stmt.handle, i);
duckdb_bind_internal(stmt::Stmt, i::Integer, val::Nothing) = duckdb_bind_null(stmt.handle, i);
duckdb_bind_internal(stmt::Stmt, i::Integer, val::AbstractString) =
    duckdb_bind_varchar_length(stmt.handle, i, val, ncodeunits(val));
duckdb_bind_internal(stmt::Stmt, i::Integer, val::Vector{UInt8}) = duckdb_bind_blob(stmt.handle, i, val, sizeof(val));
duckdb_bind_internal(stmt::Stmt, i::Integer, val::WeakRefString{UInt8}) =
    duckdb_bind_varchar_length(stmt.handle, i, val.ptr, val.len);
function duckdb_bind_internal(stmt::Stmt, i::Integer, val::AbstractVector{T}) where {T}
    value = create_value(val)
    return duckdb_bind_value(stmt.handle, i, value.handle)
end

function duckdb_bind_internal(stmt::Stmt, i::Integer, val::Any)
    println(val)
    throw(NotImplementedException("unsupported type for bind"))
end

function bind_parameters(stmt::Stmt, params::DBInterface.PositionalStatementParams)
    i = 1
    for param in params
        if duckdb_bind_internal(stmt, i, param) != DuckDBSuccess
            throw(QueryException("Failed to bind parameter"))
        end
        i += 1
    end
end

function bind_parameters(stmt::Stmt, params::DBInterface.NamedStatementParams)
    N = nparameters(stmt)
    if length(params) == 0
        return # no parameters to bind
    end
    K = eltype(keys(params))
    for i in 1:N
        name_ptr = duckdb_parameter_name(stmt.handle, i)
        name = unsafe_string(name_ptr)
        duckdb_free(name_ptr)
        name_key = K(name)
        if !haskey(params, name_key)
            if isa(params, NamedTuple)
                value = params[i] # FIXME this is a workaround to keep the interface consistent, see the test in test_sqlite.jl
            else
                throw(QueryException("Parameter '$name' not found"))
            end
        else
            value = getindex(params, name_key)
        end
        if duckdb_bind_internal(stmt, i, value) != DuckDBSuccess
            throw(QueryException("Failed to bind parameter '$name'"))
        end
    end
end
