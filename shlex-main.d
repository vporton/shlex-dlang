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
    if (args.length == 1)
        _printTokens(*new Shlex(stdin.readFile));
    else {
        immutable filename = args[1];
        scope File file = File(filename, "r");

        auto provider = new ShlexProviderStream!(char[]).ShlexProvider;
        ShlexProviderStream!(char[]).ShlexParams.WithDefaults params = {instream: file.readFile, infile: nullable(filename)};
        Shlex *shlex = provider.callWithDefaults(params);

        //_printTokens(*new Shlex(file.readFile, nullable(filename)));
        _printTokens(shlex);
    }
}
