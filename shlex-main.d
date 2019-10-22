module shlex_main;

import std.stdio;
import std.typecons;
import shlex;

void main(string[] args)
{
    if (args.length == 1)
        _printTokens(*new Shlex(stdin));
    else {
        immutable filename = args[1];
        scope File file = File(filename, "r");
        _printTokens(*new Shlex(file, Nullable!string(filename)));
    }
}
