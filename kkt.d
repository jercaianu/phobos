import std.path;
import std.string;
import std.conv;
import std.ascii;
import std.internal.cstring;
import std.process;
import std.file;
import std.exception;

private struct TestScript
{
    this(string code) @system
    {
        // @system due to chmod
        import std.ascii : newline;
        import std.file : write;
        version (Windows)
        {
            auto ext = ".cmd";
            auto firstLine = "@echo off";
        }
        else version (Posix)
        {
            auto ext = "";
            auto firstLine = "#!" ~ nativeShell;
        }
        path = uniqueTempPath()~ext;
        write(path, firstLine ~ newline ~ code ~ newline);
        version (Posix)
        {
            import core.sys.posix.sys.stat : chmod;
            chmod(path.tempCString(), octal!777);
        }
    }

    ~this()
    {
        import std.file : remove, exists;
        if (!path.empty && exists(path))
        {
            try { remove(path); }
            catch (Exception e)
            {
                debug std.stdio.stderr.writeln(e.msg);
            }
        }
    }

    string path;
}
private string uniqueTempPath() @safe
{
    import std.file : tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    // Path should contain spaces to test escaping whitespace
    return buildPath(tempDir(), "std.process temporary file " ~
            randomUUID().toString());
}
void main()
{
    TestScript prog = "echo";
    import core.sys.posix.sys.stat : S_IRUSR;
    auto directoryNoSearch = uniqueTempPath();
    mkdir(directoryNoSearch);
    scope(exit) rmdirRecurse(directoryNoSearch);
    setAttributes(directoryNoSearch, S_IRUSR);
    spawnProcess(prog.path, null, Config.none, directoryNoSearch);
}
