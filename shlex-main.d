module shlex_main;

import std.stdio;
import std.typecons;
import std.file;
import std.utf;
import std.array;
import shlex;

// TODO: byLine is inefficient.
void main(string[] args)
{
    if (args.length == 1)
        _printTokens(*new Shlex(stdin.byLine(Yes.keepTerminator).join));
    else {
        immutable filename = args[1];
        scope File file = File(filename, "r");
        _printTokens(*new Shlex(file.byLine(Yes.keepTerminator).join,
                                Nullable!string(filename)));
    }
}
