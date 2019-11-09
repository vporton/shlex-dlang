module shlex_main;

import std.stdio;
import std.typecons;
import std.file;
import std.utf;
import std.array;
import std.algorithm;
import shlex;

// TODO: inefficient.
auto readFile(File file) {
    return file.byLine(Yes.keepTerminator).join;
}

void main(string[] args)
{
    auto provider = new ShlexProviderStream!(char[]).ShlexProvider;

    alias ParamsType = ShlexProviderStream!(char[]).ShlexParams.WithDefaults;
    ParamsType params;
    if (args.length == 1) {
        ParamsType p = {instream: stdin.readFile, infile: Nullable!string.init};
        params = p;
    } else {
        immutable filename = args[1];
        scope File file = File(filename, "r");

        ParamsType p = {instream: file.readFile, infile: nullable(filename)};
        params = p;
    }
    Shlex *shlex = provider.callWithDefaults(params);
    _printTokens(*shlex);
}
