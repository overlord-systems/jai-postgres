AT_COMPILE_TIME :: true;

WINDOWS_PG_DIR :: "D:/Program Files/PostgreSQL/17";

DECLARATIONS_TO_OMIT :: string.[
];

#if AT_COMPILE_TIME {
    #run {
        set_build_options_dc(.{do_output=false});
        if !generate_bindings() {
            compiler_set_workspace_status(.FAILED);
        }
    }
} else {
    #import "System";

    main :: () {
        set_working_directory(path_strip_filename(get_path_of_running_executable()));
        if !generate_bindings() {
            exit(1);
        }
    }
}

generate_bindings :: () -> bool {
    output_filename: string;
    opts: Generate_Bindings_Options;
    {
        using opts;

		make_directory_if_it_does_not_exist("bindings");

        #if OS == .WINDOWS {
            output_filename          = "bindings/windows.jai";
            array_add(*include_paths, tprint("%/%", WINDOWS_PG_DIR, "include"));
            array_add(*libpaths,      tprint("%/%", WINDOWS_PG_DIR, "bin"));
            array_add(*libpaths,      tprint("%/%", WINDOWS_PG_DIR, "lib"));
            generate_library_declarations = false;
            footer = FOOTER_WIN;
        } else #if OS == .LINUX {
            output_filename          = "bindings/unix.jai";
			array_add(*include_paths, "/usr/include/postgresql");
			generate_library_declarations = false;
			footer = FOOTER_UNIX;
        } else #if OS == .MACOS {
            // @ToDo: Determine dynamically? Customize?
            array_add(*system_include_paths, "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include");
			array_add(*include_paths, "/usr/local/homebrew/opt/libpq/include");
			array_add(*libpaths, "/usr/local/homebrew/opt/libpq/lib");
            output_filename          = "bindings/unix.jai";
			generate_library_declarations = false;
			footer = FOOTER_MACOS;
        } else {
            assert(false);
        }

        array_add(*libnames,      "libpq");
        array_add(*source_files,  "libpq-fe.h");
        array_add(*extra_clang_arguments, "-x", "c");
        auto_detect_enum_prefixes = false;
        generate_compile_time_struct_checks = false;
        strip_flags |= .INLINED_FUNCTIONS; // "inline" functions are not present in the static library.
    }

    return generate_bindings(opts, output_filename);
}

#import "Basic";
#import "Bindings_Generator";
#import "Compiler";
#import "File";
#import "String";

FOOTER_UNIX :: #string END

libpq :: #system_library "libpq";

END

FOOTER_MACOS :: #string END
libpq :: #library,no_dll "libpq";

libpgport_shlib :: #library,no_dll,link_always "libpgport_shlib";
libpgcommon_shlib :: #library,no_dll,link_always "libpgcommon_shlib";

libcrypto :: #library,no_dll,link_always "libcrypto";
libssl :: #library,no_dll,link_always "libssl";

liblber :: #library,no_dll,link_always "liblber";
libldap :: #library,no_dll,link_always "libldap";
libsasl :: #library,link_always "libsasl2.3";
kerberos :: #library,system,link_always "Kerberos";
END

FOOTER_WIN :: #string END

libpq :: #library,no_dll "libpq";

END
