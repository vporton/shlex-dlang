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
        _printTokens(*new Shlex(file.readFile, nullable(filename)));
    }
}
