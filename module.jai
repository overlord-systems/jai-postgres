#module_parameters ()(SUPPORT_DATE_AS_STRINGS := false); // SUPPORT_DATE requires https://github.com/rluba/jai-date, at least for now.

// Those are variables because we need to take their addresses
BOOL_TRUE_VALUE : u8 = 1;
BOOL_FALSE_VALUE: u8 = 0;

connect :: (conn_str: string) -> *PGconn, success: bool {
    conn_c_str := to_c_string(conn_str);
    defer free(conn_c_str);
    conn := PQconnectStart(conn_c_str);
    if PQstatus(conn) == ConnStatusType.CONNECTION_BAD {
        log_error("Couldn’t start connecting\n");
        return conn, false;
    }

    result := PQconnectPoll(conn);
    while result != PostgresPollingStatusType.PGRES_POLLING_OK && result != PostgresPollingStatusType.PGRES_POLLING_FAILED {
        newResult := PQconnectPoll(conn);
        // if (result != newResult) {
        //     print("Connecting… %\n", result);
        // }
        result = newResult;
    }

    if result == PostgresPollingStatusType.PGRES_POLLING_FAILED {
        log_error("Couldn’t connect: %\n", PQstatus(conn));
        return conn, false;
    }
    return conn, true;
}

connect_start :: (conn_str: string) -> ok: bool, *PGconn {

    pgconn := PQconnectStart(temp_c_string(conn_str));

    if PQstatus(pgconn) == ConnStatusType.CONNECTION_BAD {

        log("failed to start postgres connection", flags=.ERROR);
        PQfinish(pgconn);
        return false, null;
    }

    return true, pgconn;
}

connect_tick :: (pgconn: *PGconn) -> ok: bool, done: bool {

    // The docs talk about sockets this and that, but it seems that socket checks
    // here are for the app so it can sleep and not poll libpq, but libpq itself doesn't
    // mind being polled all the time.
    //
    // All this to say, we don't waste our time with that here.
    result := PQconnectPoll(pgconn);

    if result == .PGRES_POLLING_FAILED {
        log("failed to establish postgres connection in connect_tick with status=%", PQstatus(pgconn), flags=.ERROR);
        return false, false;
    }

    if result == .PGRES_POLLING_OK {
        return true, true;
    }

    return true, false;
}

reset_start :: (pgconn: *PGconn) -> ok: bool {

    status := PQresetStart(pgconn);

    return status == 1;
}

reset_tick :: (pgconn: *PGconn) -> ok: bool, done: bool {

    // The docs talk about sockets this and that, but it seems that socket checks
    // here are for the app so it can sleep and not poll libpq, but libpq itself doesn't
    // mind being polled all the time.
    //
    // All this to say, we don't waste our time with that here.
    result := PQresetPoll(pgconn);

    if result == .PGRES_POLLING_FAILED {
        log("failed to reset postgres connection with status=%", PQstatus(pgconn), flags=.ERROR);
        return false, false;
    }

    if result == .PGRES_POLLING_OK {
        return true, true;
    }

    return true, false;
}

disconnect :: (conn: *PGconn) {
    if conn {
        PQfinish(conn);
    }
}

// Execute a statement and parse the result
execute :: (conn: *PGconn, $T: Type, command: string, args: .. Any, $ignore_unknown := false) -> [] T, success: bool {
    success := send_query(conn, command, ..args);
    if !success return .[], false;

    query_res := get_last_query_result(conn);
    defer PQclear(query_res);

    has_results: bool;
    results: [] T;
    has_results, success = check_query_result(query_res);
    if !success        return results, false;

    if has_results {
        results, success = get_results(query_res, T, ignore_unknown);
    }
    return results, success;
}

// Execute a statement without parsing the result (eg. for DELETE et al)
execute :: (conn: *PGconn, command: string, args: .. Any) -> success: bool, update_rows: int {
    success := send_query(conn, command, ..args);
    if !success false;

    query_res := get_last_query_result(conn);
    defer PQclear(query_res);

    has_results: bool;
    update_rows: int;
    has_results, success, update_rows = check_query_result(query_res);

    return success, update_rows;
}

execute_async :: (conn: *PGconn, command: string, args: ..Any) -> ok: bool {

    ok := send_query(conn, command, ..args);
    if !ok {
        return false;
    }

    return true;
}

execute_async_raw :: (conn: *PGconn, command: string) -> ok: bool {

    ok := send_query_raw(conn, command);
    if !ok {
        return false;
    }

    return true;
}

execute_async_params :: (conn: *PGconn, command: string, param_types: []Oid, param_values: []*u8, param_lengths: []s32, param_formats: []s32) -> ok: bool {

    ok := send_query_params(conn, command, param_types, param_values, param_lengths, param_formats);
    if !ok {

        error_message: string;
        error_message.data = PQerrorMessage(conn);
        error_message.count = c_style_strlen(error_message.data);
        log_error("Could not send query: %", error_message);
        return false;
    }

    return true;
}

query_results_ready :: (conn: *PGconn) -> (success: bool, ready: bool) {

    code := PQconsumeInput(conn);
    if code != 1 {
        err := read_latest_error(conn);
        log_error("calling PQconsumeInput in has_results failed with code=% and err=%", code, err);
        return false, false;
    }

    ready_to_read := !is_busy(conn);
    return true, ready_to_read;
}

is_busy :: inline (conn: *PGconn) -> bool {
    return PQisBusy(conn) == 1;
}

// Parse results of a previously sent statement
read_query_results :: (conn: *PGconn, $T: Type, $$ignore_unknown := false) -> [] T, success: bool {

    results: [] T;
    query_res := get_last_query_result(conn);

    // No async query was run
    if !query_res {
        return results, false;
    }

    defer PQclear(query_res);

    has_results, success := check_query_result(query_res);
    if !success return results, false;

    if has_results {
        results, success = get_results(query_res, T, ignore_unknown);
    }

    return results, success;
}

read_query_results_no_parse :: (conn: *PGconn) -> success: bool, has_results: bool, pgresult: *PGresult, updated_rows: int {

    query_res := get_last_query_result(conn);

    // No async query was run
    if !query_res {
        return false, false, null, 0;
    }

    has_results, success, updated_rows := check_query_result(query_res);
    return success, has_results, query_res, updated_rows;
}

read_query_results :: (conn: *PGconn) -> success: bool, update_rows: int {

    query_res := get_last_query_result(conn);

    // No async query was run
    if !query_res {
        return results, false;
    }

    defer PQclear(query_res);

    has_results, success, update_rows := check_query_result(query_res);
    return success, update_rows;
}

// The returned string should NOT be freed, and should be
// considered invalid after the next connection operation.
read_latest_error :: inline (conn: *PGconn) -> string {
    err_msg: string = ---;
    err_msg.data = PQerrorMessage(conn);
    err_msg.count = c_style_strlen(err_msg.data);

    return err_msg;
}

type_to_pq_type :: (ti: *Type_Info) -> (success: bool, Pq_Type) {

    if ti.type == {
        case .INTEGER;

            info := ti.(*Type_Info_Integer);

            // @TODO: implement unsigned ints
            assert(info.signed, "Unsigned not yet supported");

            if info.runtime_size == {
                case 2;
                    return true, Pq_Type.INT2;
                case 4;
                    return true, Pq_Type.INT4;
                case 8;
                    return true, Pq_Type.INT8;
                case;
                    return false, 0;
            }

        case .FLOAT;

            if ti.runtime_size == {
                case 4;
                    return true, Pq_Type.FLOAT4;
                case 8;
                    return true, Pq_Type.FLOAT8;
                case;
                    return false, 0;
            }

        case .STRING;
            return true, Pq_Type.TEXT;

        case .BOOL;
            return true, Pq_Type.BOOL;

        case;
            log_error("failed to convert type=% to Pq_Type because type is unknown or unhandled", ti.type);
            return false, 0;
    }
}

send_query_raw :: (conn: *PGconn, command: string) -> success: bool {

    // Alloc in case it's big
    c_command := to_c_string(command);
    defer free(c_command);

    result := PQsendQuery(conn, c_command);
    if result == 0 {
        error_msg := to_string(PQerrorMessage(conn));
        log("failed postgres send_query_raw. Error = %; Query = %", error_msg, command, flags=.ERROR);
        return false;
    }

    return true;
}

send_query :: (conn: *PGconn, command: string, args: ..Any) -> success: bool {

    pool: Pool;
    set_allocators(*pool, Context_Base.default_allocator);
    defer release(*pool);

    push_allocator(pool_allocator_proc, *pool);

    ok, param_types, param_values, param_lengths, param_formats := pg_query_args_to_send_params(..args);
    if !ok return false;

    ok = inline send_query_params(conn, command, param_types, param_values, param_lengths, param_formats);
    return ok;
}

send_query_params :: (conn: *PGconn, command: string, param_types: []Oid, param_values: []*u8, param_lengths: []s32, param_formats: []s32) -> success: bool {

    // Alloc in case it's big
    c_command := to_c_string(command);
    defer free(c_command);

    result := PQsendQueryParams(conn, c_command, param_types.count.(s32,no_check), param_types.data, param_values.data, param_lengths.data, param_formats.data, 1);
    if result == 0 {
        error_msg := to_string(PQerrorMessage(conn));
        log("failed postgres send_query. Error = %; Query = %", error_msg, command, flags=.ERROR);
        return false;
    }

    return true;
}

pg_query_args_to_send_params :: (args: ..Any) -> ok: bool, param_types: []Oid=.[], param_values: []*u8=.[], param_lengths: []s32=.[], param_formats: []s32=.[] {

    param_types   := NewArray(args.count, Oid, initialized = false);
    param_values  := NewArray(args.count, *u8, initialized = false);
    param_lengths := NewArray(args.count, s32, initialized = false);
    param_formats := NewArray(args.count, s32, initialized = false);

    for arg_original, index: args {

        arg := arg_original; // Shadow to handle pointers if needed

        // Handle (one level of) pointers by dereferencing into the underlying type
        if arg.type.type == .POINTER {

            underlying_ti := arg.type.(*Type_Info_Pointer).pointer_to;

            // Handle null pointers
            if !arg.value_pointer.(**void).* {

                success, postgres_type := type_to_pq_type(underlying_ti);
                if !success {
                    log("failed postgres pg_query_args_to_send_params because of unsupported type: pointer of % in arg[%]=%", underlying_ti.*, index, arg, flags=.ERROR);
                    return false;
                }

                param_types[index] = postgres_type.(Oid);
                param_values[index] = null;
                param_lengths[index] = 0;
                param_formats[index] = 1;
                continue;
            }

            // Non-null pointer so update arg to be the underlying value and type
            arg.type = underlying_ti;
            arg.value_pointer = arg.value_pointer.(**void).*;
        }

        if arg.type.type == {

            case .ENUM; #through;
            case .INTEGER;

                info := ifx arg.type.type == .ENUM then arg.type.(*Type_Info_Enum).internal_type else arg.type.(*Type_Info_Integer);

                // @TODO: implement unsigned ints
                if !info.signed {
                    log("failed postgres pg_query_args_to_send_params because arg with index=% is an unsigned integer, which isn't supported yet. Type info=%", index, info.*, flags=.ERROR);
                    return false;
                }

                be_value := alloc(info.runtime_size).(*u8);
                if info.runtime_size == {
                    case 2;
                        param_types[index] = Pq_Type.INT2.(Oid);
                        be_val := hton(arg.value_pointer.(*s16).*);
                        memcpy(be_value, *be_val, info.runtime_size);
                    case 4;
                        param_types[index] = Pq_Type.INT4.(Oid);
                        be_val := hton(arg.value_pointer.(*s32).*);
                        memcpy(be_value, *be_val, info.runtime_size);
                    case 8;
                        param_types[index] = Pq_Type.INT8.(Oid);
                        be_val := hton(arg.value_pointer.(*s64).*);
                        memcpy(be_value, *be_val, info.runtime_size);
                    case;
                        log("failed pg_query_args_to_send_params because arg_type=% had an unexpected runtime_size=%", arg.type.type, info.runtime_size, flags=.ERROR);
                        return false;
                }
                param_values[index] = be_value;
                param_lengths[index] = info.runtime_size.(s32);
                param_formats[index] = 1;

            case .FLOAT;
                be_value := alloc(arg.type.runtime_size).(*u8);
                if arg.type.runtime_size == 4 {
                    param_types[index] = Pq_Type.FLOAT4.(Oid);
                    be_val := hton(arg.value_pointer.(*float).*);
                    memcpy(be_value, *be_val, arg.type.runtime_size);
                }
                if arg.type.runtime_size == 8 {
                    param_types[index] = Pq_Type.FLOAT8.(Oid);
                    be_val := hton(arg.value_pointer.(*float64).*);
                    memcpy(be_value, *be_val, arg.type.runtime_size);
                }
                param_values[index] = be_value;
                param_lengths[index] = arg.type.runtime_size.(s32);
                param_formats[index] = 1;

            case .STRING;
                str := arg.value_pointer.(*string);
                param_types[index] = Pq_Type.TEXT.(Oid);
                param_values[index] = ifx str.data else ""; // This handles empty strings. Sending no data means null string
                param_lengths[index] = str.count.(s32);
                param_formats[index] = 1;

            case .BOOL;
                val := ifx arg.value_pointer.(*bool);
                param_types[index] = Pq_Type.BOOL.(Oid);
                param_values[index] = ifx val.* then *BOOL_TRUE_VALUE else *BOOL_FALSE_VALUE;;
                param_lengths[index] = 1;
                param_formats[index] = 1;

            // case .ARRAY;
                // @TODO: Implement binary format according to array_recv format.
                // See https://doxygen.postgresql.org/arrayfuncs_8c.html#a315b67e6e01e8f283326b5a6b27e07c9
                //
                // Format seems to be:
                //   4 byte number of dimensions
                //   4 byte flags (seems unused, but must be 0 or 1)
                //   4 byte element type (sizeof OID, actually…)
                // Then for each dimension:
                //   4 byte number of elements
                //   4 byte lower bound
                // Then for each element:
                //   4 byte length
                //   n byte encoded element
                //
                // But given the overhead, maybe it would be smarter to just serialize arrays as strings?
                // Eg. an array of two ints would be 28 bytes + 2 * int size.
                // The string equivalent would be 3 bytes + string-size of the integers

            // ToDo: Struct as Jsonb?

            case;
                log("failed pg_query_args_to_send_params because arg at index=% is of an unsupported param type=%", index, arg.type.type, flags=.ERROR);
                return false;
        }
    }

    return true, param_types, param_values, param_lengths, param_formats;
}


get_last_query_result :: (conn: *PGconn) -> *PGresult {
    query_result: *PGresult;
    while true {
        latest_result := PQgetResult(conn);
        if latest_result == null break;
        if query_result PQclear(query_result);
        query_result = latest_result;
    }

    return query_result;
}

// @bloeys: I removed logs from here because we don't want noise. The user can use PGresult to do whatever they want.
check_query_result :: (query_res: *PGresult) -> has_results: bool, success: bool, updated_rows: int {
    res_status := PQresultStatus(query_res);
    if res_status == {
        case ExecStatusType.PGRES_EMPTY_QUERY;
            return false, true, 0;
        case ExecStatusType.PGRES_COMMAND_OK;
            rows_affected := to_string(PQcmdTuples(query_res));
            rows_affected_count := string_to_int(rows_affected);

            return false, true, rows_affected_count;
        case ExecStatusType.PGRES_TUPLES_OK;
            return true, true, 0;
        case ExecStatusType.PGRES_FATAL_ERROR;
            // error_message := to_string(PQresultErrorMessage(query_res));
            // log_error("Fatal error: %", error_message);
            return false, false, 0;
        case ExecStatusType.PGRES_NONFATAL_ERROR;
            // error_message := to_string(PQresultErrorMessage(query_res));
            // log_error("Non-fatal error: %", error_message);
            return false, false, 0;
        case;
            // log_error("Query result status: %", res_status);
            return false, false, 0;
    }
}

get_results :: (query_res: *PGresult, $T: Type, $$ignore_unknown := false) -> [] T, success: bool {
    raw_result, success := get_results(query_res, type_info(T), ignore_unknown);

    results: []T;
    results.data = xx raw_result.data;
    results.count = raw_result.count;
    return results, success;
}

Member_Offset :: struct {
    member: *Type_Info_Struct_Member;
    offset_in_bytes: s64;
}

get_results :: (query_res: *PGresult, info: *Type_Info, ignore_unknown := false) -> Array_View_64, success: bool {
    // @ToDo: Allow to cast single-column results directly to primitive types
    assert(info.type == .STRUCT);
    info_struct := info.(*Type_Info_Struct);
    initializer := info_struct.initializer;

    num_tuples := PQntuples(query_res);
    results: Array_View_64;
    // This check is to keep flat_pool happy, as the memory debugger in beta 0.2.010 complains with 0-byte allocs on flat_pool.
    // Aside from the flat_pool thing, this check isn't really needed
    if num_tuples > 0 {
        results.data = alloc(info.runtime_size * num_tuples);
        results.count = num_tuples;
        if !initializer {
            memset(results.data, 0, info.runtime_size * num_tuples);
        }
    }

    num_columns := PQnfields(query_res);
    column_members := NewArray(num_columns, Member_Offset, initialized = false,, Context_Base.default_allocator);
    defer array_free(column_members);

    for col: 0..num_columns - 1 {
        name: string;
        name.data = PQfname(query_res, col);
        name.count = c_style_strlen(name.data);
        member, offset_in_bytes := get_field(info_struct, name);
        if !ignore_unknown && !member {
            log_error("Column \"%\" has no corresponding member in struct type \"%\"", name, info_struct.*);
            return results, false;
        }
        column_members[col] = {member, offset_in_bytes};
    }

    for row: 0..num_tuples - 1 {
        row_data := results.data + (info.runtime_size * row);
        if initializer initializer(row_data);

        for col: 0..num_columns - 1 {
            member_offset := column_members[col];
            if !member_offset.member    continue;

            if PQgetisnull(query_res, row, col) {
                // @ToDo: Handle pointer member types and null them
                // We keep the value as default instead, atm.
            } else {
                type := PQftype(query_res, col);
                len := PQgetlength(query_res, row, col);
                data := PQgetvalue(query_res, row, col);
                slot := row_data + member_offset.offset_in_bytes;
                success := assign_member(member_offset.member.name, member_offset.member.type, slot, type.(Pq_Type), len, data, row, col);
                if !success        return results, false;
            }
        }
    }

    return results, true;
}

#scope_module

assign_member :: (name: string, info: *Type_Info, slot: *u8, col_type: Pq_Type, len: int, data: *u8, row: int, col: int) -> bool {

    info = variant_to_base_type_info(info);

    if col_type == {
        case .INT2;
            assert(len == 2);
            // Explicitly throwing away 48 bits.
            val := ntoh(data.(*s16).*);
            return write_integer(col, name, info, slot, col_type, val);

        case .OID; #through;
        case .INT4;
            assert(len == 4);
            // Explicitly throwing away 32 bits.
            val := ntoh(data.(*s32).*);
            return write_integer(col, name, info, slot, col_type, val);

        case .INT8;
            assert(len == 8);
            val := ntoh(data.(*s64).*);
            return write_integer(col, name, info, slot, col_type, val);

        case .FLOAT4;
            if info.type != Type_Info_Tag.FLOAT {
                log_error("Error: Trying to write float4 column % into member field \"%\" of type %", col, name, info.type);
                return false;
            }

            if info.runtime_size == 4 {
                slot.(*float32).* = ntoh(data.(*float32).*);
            } else {
                assert(info.runtime_size == 8);
                slot.(*float64).* = ntoh(data.(*float32).*).(float64);
            }
            return true;

        case .FLOAT8;
            if info.type != Type_Info_Tag.FLOAT {
                log_error("Error: Trying to write float8 column % into member field \"%\" of type %", col, name, info.type);
                return false;
            }

            if info.runtime_size == 4 {
                slot.(*float32).* = ntoh(data.(*float64).*).(float32);
            } else {
                assert(info.runtime_size == 8);
                slot.(*float64).* = ntoh(data.(*float64).*);
            }
            return true;

        case .NUMERIC;
            if info.type != Type_Info_Tag.STRING {
                log_error("Error: Trying to write numeric column % into member field \"%\" of type %, but we only support writing to string fields at the moment.", col, name, info.type);
                return false;
            }
            success: bool;
            slot.(*string).*, success = str_from_numeric(data, len, row, col);
            return success;

        case .BOOL;
            assert(len == 1);
            if info.type != Type_Info_Tag.BOOL {
                log_error("Error: Trying to write bool column % into member field \"%\" of type %", col, name, info.type);
                return false;
            }

            val := data.(*u8).*;
            slot.(*bool).* = (val != 0);

            return true;

        case .CHAR; #through;
        case .BPCHAR; #through;
        case .VARCHAR; #through;
        case .NAME; #through;
        case .TEXT;
            val: string;
            val.data = data;
            val.count = len;
            write_string_value(col, name, info, slot, col_type, val, is_custom = false);
            return true;

        case .DATE;
            assert(len == 4);
            days_since_2000_01_01 := ntoh(data.(*s32).*);
            if info.type == Type_Info_Tag.INTEGER {
                return write_integer(col, name, info, slot, col_type, days_since_2000_01_01);
            } else {
                #if SUPPORT_DATE_AS_STRINGS {
                    #import "date"; // https://github.com/rluba/jai-date
                    date := Date.{2000, 1, 1};
                    add(*date, days_since_2000_01_01, .DAY);
                    if info == type_info(Date) {
                        target := slot.(*Date);
                        target.* = date;
                        return true;
                    } else if info == type_info(Apollo_Time) {
                        target := slot.(*Apollo_Time);
                        target.* = to_apollo_time(date);
                        return true;
                    } else {
                        date_string := string_from_date(date, .ISO);
                        return write_string_value(col, name, info, slot, col_type, date_string, is_custom = false);
                    }
                } else {
                    log_error("Error: Trying to write column % of type % into member field \"%\" of type %", col, col_type, name, info.type);
                    return false;
                }
            }
        case .TIMESTAMP;   #through;
        case .TIMESTAMPTZ;
            val := ntoh(data.(*s64).*);
            // shift from 2000 to 1970
            val += 946_684_800_000000;
            if info.type == .STRING || info == type_info(Apollo_Time) {
                a_seconds     :=     seconds_to_apollo(val / 1_000_000);
                a_nanoseconds := nanoseconds_to_apollo((val % 1_000_000) * 1000);

                apollo := a_seconds + a_nanoseconds + APOLLO_TIME_FOR_JAN_1_1970;

                if info == type_info(Apollo_Time) {
                    target := slot.(*Apollo_Time);
                    target.* = apollo;
                    return true;
                } else {
                    calendar := to_calendar(apollo);
                    iso := calendar_to_iso_string(calendar);
                    return write_string_value(col, name, info, slot, col_type, iso, is_custom = false);
                }
            } else {
                return write_integer(col, name, info, slot, col_type, val);
            }

        case .UUID; #through;
        case .BYTEA;
            if info.type == .ARRAY {
                array_info := info.(*Type_Info_Array);
                element_size := array_info.element_type.runtime_size;
                assert(element_size != -1);
                if element_size != 1 {
                    log_error("Error: Trying to write column % of type % with array count % into member field \"%\" with array element size of % instead of 1!", col, col_type, len, name, element_size);
                    return false;
                }

                dest_data_pointer: *void;
                if array_info.array_type == .VIEW {
                    view := slot.(*Array_View_64);
                    view.count = len;
                    view.data = alloc(len * element_size);
                    dest_data_pointer = view.data;
                } else if array_info.array_count == -1 {
                    resizable_array := slot.(*Resizable_Array);
                    array_reserve(resizable_array, len, element_size);
                    resizable_array.count = len;
                    dest_data_pointer = resizable_array.data;
                } else {
                    if array_info.array_count != len {
                        log_error("Error: Trying to write column % of type % with array count % into member field \"%\", which is a fixed-size array with count %. For fixed-size arrays, the size must match!", col, col_type, len, name, array_info.array_count);
                        return false;
                    }
                    dest_data_pointer = slot;
                }

                memcpy(dest_data_pointer, data, element_size * len);
                return true;
            } else {
                log_error("Error: Trying to write column % of type % into member field \"%\" of type %", col, col_type, name, info.type);
                return false;
            }

        case;

            // See if we have a handler that knows how to deal with this type
            for pg_custom_type_handlers {
                if it.oid != col_type.(Oid) continue;
                return it.handler(name, info, slot, col_type, len, data, row, col);
            }

            if col_type.(s64) > enum_highest_value(Pq_Type) {
                // Seems to be a custom type. Try to interpret it as a string
                val: string;
                val.data = data;
                val.count = len;
                return write_string_value(col, name, info, slot, col_type, val, is_custom = true);
            } else {
                log_error("Error: column % type % (with length %) is not yet implemented (for member %)", col, col_type, len, name);
            }
            return false;
    }
}

write_string_value :: (col: int, name: string, info: *Type_Info, slot: *void, col_type: Pq_Type, value: string, is_custom: bool) -> bool {

    if info.type == {
        case .STRING;
            slot.(*string).* = copy_string(value);
            return true;
        case .ENUM;
            info_enum := info.(*Type_Info_Enum);
            for info_enum.names {
                if it == value {
                    return write_integer(col, name, info_enum.internal_type, slot, col_type, info_enum.values[it_index]);
                }
            }

            log_error("Error: Could not find an enum value for value \"%\" of column % for member field \"%\"", value, col, name);
            return false;
        case;
            if is_custom {
                log_error("Error: Trying to write custom type of column % into member field \"%\" of type %", col, name, info.type);
            } else {
                log_error("Error: Trying to write column % of type % into member field \"%\" of type %", col, col_type, name, info.type);
            }
            return false;
    }
}

write_integer :: (col: int, name: string, info: *Type_Info, pointer: *void, col_type: Pq_Type, value: s64) -> bool {

    if info.type != Type_Info_Tag.INTEGER && info.type != .ENUM {
        log_error("Error: Trying to write column % of type % as an integer into member field \"%\" of type %", col, col_type, name, info.type);
        return false;
    }
    int_info := info.(*Type_Info_Integer);

    if int_info.signed {
        valid, low, high := Reflection.range_check_and_store(value, int_info, pointer);

        if !valid {
            log_error("Value % of column % is out of range for \"%\". (The value must be between % and %.)", value, col, name, low, high);
            return false;
        }
    } else {
        valid, low, high := Reflection.range_check_and_store(value.(u64), int_info, pointer);  // Different overload from the above!

        if !valid {
            log_error("Value % of column % is out of range for \"%\". (The value must be between % and %.)", value, col, name, low, high);
            return false;
        }
    }

    return true;
}

str_from_numeric :: (data: *u8, len: int, row: int, col: int) -> string, success: bool {
    if len < 8 {
        log_error("Invalid numeric length at row % col %: %", row, col, len);
        return "", false;
    }

    num_digits := ntoh(data.(*u16).*);
    weight := ntoh((data + 2).(*s16).*);
    sign := ntoh((data + 4).(*u16).*);
    dscale := ntoh((data + 6).(*u16).*);
    if len != num_digits * 2 + 8 {
        log_error("Invalid numeric length at row % col %: %", row, col, len);
        return "", false;
    }
    if dscale > 0x3fff {
        log_error("Invalid numeric dscale at row % col %: %", row, col, dscale);
        return "", false;
    }

    builder: String_Builder;
    defer free_buffers(*builder);

    if sign == {
        case 0x0000;

        case 0x4000;
            append(*builder, "-");

        case 0xc000;
            append(*builder, "NaN");

        case;
            log_error("Invalid numeric sign at row % col%: %", row, col, sign);
            return "", false;
    }

    index := 0;
    if weight >= 0 && num_digits {
        min_digits := 1;
        while weight >= 0 && index < num_digits {
            digit := ntoh((data + 8 + index * 2).(*s16).*);
            print_to_builder(*builder, "%", formatInt(digit, minimum_digits=min_digits));
            min_digits = 4;
            weight -= 1;
            index += 1;
        }
        while weight >= 0 {
            append(*builder, "0000");
            weight -= 1;
        }
    } else {
        append(*builder, "0");
    }

    if dscale != 0     append(*builder, ".");
    dec_len := 0;

    omitted := -1 - weight;
    if omitted > 0 {
        zeros: int;
        if 4 * omitted > dscale.(s32) {
            zeros = dscale;
        } else {
            zeros = 4 * omitted;
        }
        print_to_builder(*builder, "%", formatInt(0, minimum_digits=zeros));
        dec_len += zeros;
    }
    min_digits := 4;
    while index < num_digits {
        digit := ntoh((data + 8 + index * 2).(*s16).*);
        if dec_len + 4 > dscale {
            remaining := dscale - dec_len;
            assert(remaining > 0, "Unexpected number of remaining digits: %", remaining);
            for 1..(4 - remaining)     digit /= 10;
            min_digits = remaining;
        }
        print_to_builder(*builder, "%", formatInt(digit, minimum_digits=min_digits));
        index += 1;
        dec_len += min_digits;
    }
    if (dec_len < dscale) {
        print_to_builder(*builder, "%", formatInt(0, minimum_digits=dscale-dec_len));
    }

    return builder_to_string(*builder), true;
}

variant_to_base_type_info :: inline (info: *Type_Info) -> *Type_Info {

	// Info can be null sometimes so make sure before checking type
	if !info return null;

	while info.type == .VARIANT {
		info = info.(*Type_Info_Variant).variant_of;
	}

	return info;
}

#import "Basic";
#import "Pool";
Reflection :: #import "Reflection";

#load "byte_order.jai";
#load "pq_types.jai";
#load "custom_type_handling.jai";

#if OS == .WINDOWS {
    Windows :: #import "Windows";
    #load "bindings/windows/windows.jai";

    size_t :: Windows.size_t;
    FILE :: *void;

} else #if OS == .LINUX {
    #import "POSIX";
    #load "bindings/linux/unix.jai";
} else {
    // @TODO: This uses the system library, but ideally
    // we ship our own, just we do for linux.
    #import "POSIX";
    #load "bindings/macos/unix.jai";
}
