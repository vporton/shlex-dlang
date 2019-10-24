/*
shlex, simple shell-like lexical analysis library
Copyright (C) 2019  Victor Porton

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.

This code was a rewrite of a Python 3.7 module with the same name:
Copyright © 2001-2019 Python Software Foundation; All Rights Reserved
*/

module shlex;

import std.typecons;
import std.conv;
import std.string;
import std.utf;
import std.regex;
import std.array;
import std.range.interfaces;
import std.range.primitives;
import std.container.dlist;
import std.algorithm;
import std.file;
import std.path;
import std.stdio : write, writeln;

// TODO: use moveFront()/moveBack()

alias ShlexStream = InputRange!(const dchar); // Unicode stream

class ShlexFile : InputRange!dchar {
    private string text;

    /// The current version reads the file entirely
    this(string name) {
        text = readText(name);
    }

    override @property dchar front() {
        return text.front;
    }

    override dchar moveFront() {
        return text.moveFront();
    }

    override void popFront() {
        return text.popFront();
    }

    override @property bool empty() {
        return text.empty;
    }

    override int opApply(scope int delegate(dchar) dg) {
        int res;
        for (auto r = text; !r.empty; r.popFront()) {
            res = dg(r.front);
            if (res) break;
        }
        return res;
    }

    override int opApply(scope int delegate(size_t, dchar) dg) {
        int res;
        size_t i = 0;
        for (auto r = text; !r.empty; r.popFront()) {
            res = dg(i, r.front);
            if (res) break;
            i++;
        }
        return res;
    }

    ///
    void close() { } // we have already read the file
}

private void skipLine(ShlexStream stream) {
    while (!stream.empty && stream.front != '\n') stream.popFront();
    if (!stream.empty && stream.front == '\n') stream.popFront();
}

/// A lexical analyzer class for simple shell-like syntaxes
struct Shlex {
    alias Posix = Flag!"posix";
    alias PunctuationChars = Flag!"punctuationChars";
    alias Comments = Flag!"comments";

private:
    // TODO: Python shlex has some of the following as public instance variables (also check visibility of member functions)
    ShlexStream instream;
    Nullable!string infile;
    Posix posix;
    Nullable!string eof; // seems not efficient
    //bool delegate(string token) isEof;
    string commenters = "#";
    string wordchars;
    static immutable whitespace = " \t\r\n";
    bool whitespaceSplit = false;
    static immutable quotes = "'\"";
    static immutable escape = "\\"; // char or string?
    static immutable escapedquotes = "\""; // char or string?
    Nullable!dchar state = ' '; // a little inefficient?
    auto pushback = DList!string(); // may be not the fastest
    uint lineno;
    ubyte debug_ = 0;
    string token = "";
    auto filestack = DList!(Tuple!(Nullable!string, ShlexStream, uint))(); // may be not the fastest
    Nullable!string source; // TODO: Represent no source just as an empty string?
    string punctuationChars;
    // _pushbackChars is a push back queue used by lookahead logic
    auto _pushbackChars = DList!dchar(); // may be not the fastest

public:
    @disable this();

    /** We don't support implicit stdin as `instream` as in Python. */
    this(ShlexStream instream,
         Nullable!string infile = Nullable!string(),
         Posix posix = No.posix,
         PunctuationChars punctuationChars = No.punctuationChars)
    {
        this.instream = instream;
        this.infile = infile;
        this.posix = posix;
        if (!posix) eof = "";
        wordchars = "abcdfeghijklmnopqrstuvwxyz" ~ "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_";
        if (posix)
            wordchars ~= "ßàáâãäåæçèéêëìíîïðñòóôõöøùúûüýþÿ" ~ "ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝÞ";
        lineno = 1;
        this.punctuationChars = punctuationChars ? "();<>|&" : "";
        if (punctuationChars) {
            // these chars added because allowed in file names, args, wildcards
            wordchars ~= "~-./*?=";
            // remove any punctuation chars from wordchars
            // TODO: Isn't it better to use dstring?
            wordchars = filter!(c => !this.punctuationChars.canFind(c))(wordchars).array.to!string;
        }
    }

    this(Stream)(Stream instream,
                 Nullable!string infile = Nullable!string(),
                 Posix posix = No.posix,
                 PunctuationChars punctuationChars = No.punctuationChars)
    {
        import std.conv;
        // TODO: Inefficient to convert to dstring in memory.
        this(cast (ShlexStream)inputRangeObject(cast (const dchar[])instream.dtext), infile, posix, punctuationChars);
    }

    void dump() {
        if (debug_ >= 3) {
//            writeln("state='", state, "\' nextchar='", nextchar, "\' token='", token, '\'');
            writeln("state='", state, "\' token='", token, '\'');
        }
    }

    /** Push a token onto the stack popped by the getToken method */
    void pushToken(string tok) {
        if (debug_ >= 1)
            writeln("shlex: pushing token " ~ tok);
        pushback.insertFront(tok);
    }

    /** Push an input source onto the lexer's input source stack. */
    void pushSource(Stream)(Stream newstream, Nullable!string newfile = Nullable!string()) {
        pushSource(inputRangeObject(instream), newfile);
    }

    /** Push an input source onto the lexer's input source stack. */
    void pushSource(ShlexStream newstream, Nullable!string newfile = Nullable!string()) {
        filestack.insertFront(tuple(this.infile, this.instream, this.lineno));
        this.infile = newfile;
        this.instream = newstream;
        this.lineno = 1;
        if (debug_) {
            if (newfile.isNull)
                writeln("shlex: pushing to stream %s".format(this.instream));
            else
                writeln("shlex: pushing to file %s".format(this.infile));
        }
    }

    /** Pop the input source stack. */
    void popSource() {
        (cast(ShlexFile)instream).close(); // a little messy
        // use a tuple library?
        auto t = filestack.front;
        filestack.removeFront();
        infile   = t[0];
        instream = t[1];
        lineno   = t[2];
        if (debug_)
            writeln("shlex: popping to %s, line %d".format(instream, lineno));
        state = ' ';
    }

    // TODO: Use empty string for None?
    /** Get a token from the input stream (or from stack if it's nonempty).
        Returns null value on eof. */
    Nullable!string getToken() {
        if (!pushback.empty) {
            immutable tok = pushback.front;
            pushback.removeFront();
            if (debug_ >= 1)
                writeln("shlex: popping token " ~ tok);
            return nullable(tok);
        }
        // No pushback.  Get a token.
        Nullable!string raw = readToken();
        // Handle inclusions
        if (!source.isNull && !source.empty) {
            while (raw == source) {
                auto spec = sourcehook(readToken());
                if (!spec.empty) {
                    auto newfile   = spec[0];
                    auto newstream = spec[1];
                    pushSource(newstream, nullable(newfile));
                }
                raw = getToken();
            }
        }
        // Maybe we got EOF instead?
        while (eof == raw) {
            if (filestack.empty)
                return eof;
            else {
                popSource();
                raw = getToken();
            }
        }
        // Neither inclusion nor EOF
        if (debug_ >= 1) {
            if (eof != raw)
                writeln("shlex: token=" ~ raw);
            else
                writeln("shlex: token=EOF");
        }
        return raw;
    }

    int opApply(scope int delegate(ref string) dg) {
        int result = 0;
        while (true) {
            auto r = getToken();
            if (r.isNull) break;
            result = dg(r.get);
            if (result) break;
        }
        return result;
    }

    // TODO: Use empty string for None?
    Nullable!string readToken() {
        bool quoted = false;
        dchar escapedstate = ' '; // TODO: use an enum
        while (true) {
            if(debug_ >= 3) {
                write("Iteration ");
                dump();
            }
            Nullable!dchar nextchar;
            if (!punctuationChars.empty && !_pushbackChars.empty) {
                nextchar = _pushbackChars.back;
                _pushbackChars.removeBack();
            } else {
                if (!instream.empty) {
                    nextchar = instream.front;
                    instream.popFront();
                }
            }
            if (nextchar == '\n')
                ++lineno;
            if (debug_ >= 3)
                writeln("shlex: in state %s I see character: %s".format(state, nextchar));
            if (state.isNull) {
                // TODO: Debugger shows that this is never reached. Is this code needed?
                token = "";        // past end of file
                break;
            } else if (state == ' ') {
                if (nextchar.isNull) {
                    state.nullify();  // end of file
                    break;
                } else if (whitespace.canFind(nextchar.get)) {
                    if (debug_ >= 2)
                        writeln("shlex: I see whitespace in whitespace state");
                    if ((token && !token.empty) || (posix && quoted))
                        break;   // emit current token
                    else
                        continue;
                } else if (commenters.canFind(nextchar.get)) {
                    instream.skipLine();
                    ++lineno;
                } else if (posix && escape.canFind(nextchar.get)) {
                    escapedstate = 'a';
                    state = nextchar;
                } else if (wordchars.canFind(nextchar.get)) {
                    token = [nextchar.get].toUTF8;
                    state = 'a';
                } else if (punctuationChars.canFind(nextchar.get)) {
                    token = [nextchar.get].toUTF8;
                    state = 'c';
                } else if (quotes.canFind(nextchar.get)) {
                    if (!posix) token = [nextchar.get].toUTF8;
                    state = nextchar;
                } else if (whitespaceSplit) {
                    token = [nextchar.get].toUTF8;
                    state = 'a';
                } else {
                    token = [nextchar.get].toUTF8;
                    if (!token.empty || (posix && quoted))
                        break;   // emit current token
                    else
                        continue;
                }
            } else if (!state.isNull && quotes.canFind(state)) {
                quoted = true;
                if (nextchar.isNull) {      // end of file
                    if (debug_ >= 2)
                        writeln("shlex: I see EOF in quotes state");
                    // XXX what error should be raised here?
                    throw new Exception("No closing quotation");
                }
                if (nextchar == state) {
                    if (!posix) {
                        token ~= nextchar;
                        state = ' ';
                        break;
                    } else
                        state = 'a';
                } else if (posix && !nextchar.isNull && escape.canFind(nextchar.get) &&
                        !state.isNull && escapedquotes.canFind(state.get)) {
                    escapedstate = state;
                    state = nextchar;
                } else
                    token ~= nextchar;
            } else if (!state.isNull && escape.canFind(state)) {
                if (nextchar.isNull) {      // end of file
                    if (debug_ >= 2)
                        writeln("shlex: I see EOF in escape state");
                    // XXX what error should be raised here?
                    throw new Exception("No escaped character");
                }
                // In posix shells, only the quote itself or the escape
                // character may be escaped within quotes.
                if (quotes.canFind(escapedstate) && nextchar != state && nextchar != escapedstate)
                    token ~= state;
                token ~= nextchar;
                state = escapedstate;
            } else if (!state.isNull && (state.get == 'a' || state.get == 'c')) {
                if (nextchar.isNull) {
                    state.nullify();   // end of file
                    break;
                } else if (whitespace.canFind(nextchar.get)) {
                    if (debug_ >= 2)
                        writeln("shlex: I see whitespace in word state");
                    state = ' ';
                    if (token || (posix && quoted))
                        break;   // emit current token
                    else
                        continue;
                } else if (commenters.canFind(nextchar.get)) {
                    instream.skipLine();
                    ++lineno;
                    if (posix) {
                        state = ' ';
                        if (!token.empty || (posix && quoted))
                            break;   // emit current token
                        else
                            continue;
                    }
                } else if (state == 'c') {
                    if (punctuationChars.canFind(nextchar.get))
                        token ~= nextchar;
                    else {
                        if (!whitespace.canFind(nextchar.get))
                            _pushbackChars.insertBack(nextchar);
                        state = ' ';
                        break;
                    }
                } else if (posix && quotes.canFind(nextchar.get))
                    state = nextchar;
                else if (posix && escape.canFind(nextchar.get)) {
                    escapedstate = 'a';
                    state = nextchar;
                } else if (wordchars.canFind(nextchar.get) || quotes.canFind(nextchar.get) || whitespaceSplit) {
                    token ~= nextchar;
                } else {
                    if (punctuationChars.empty)
                        pushback.insertFront(nextchar.get.to!string);
                    else
                        _pushbackChars.insertBack(nextchar);
                    if (debug_ >= 2)
                        writeln("shlex: I see punctuation in word state");
                    state = ' ';
                    if (!token.empty || (posix && quoted))
                        break;   // emit current token
                    else
                        continue;
                }
            }
        }
        Nullable!string result = token;
        //writeln('['~token~']');
        token = "";
        if (posix && !quoted && result == "")
            result.nullify();
        if (debug_ > 1) {
            if (!result.isNull && !result.empty) // TODO: can simplify?
                writeln("shlex: raw token=" ~ result);
            else
                writeln("shlex: raw token=EOF");
        }
        return result;
    }

    /** Hook called on a filename to be sourced.*/
    auto sourcehook(string newfile) {
        if (newfile[0] == '"')
            newfile = newfile[1..$-1];
        // This implements cpp-like semantics for relative-path inclusion.
        if (!isAbsolute(newfile))
            newfile = buildPath(dirName(infile), newfile);
        return tuple(newfile, new ShlexFile(newfile));
    }

    /** Emit a C-compiler-like, Emacs-friendly error-message leader. */
    string errorLeader(Nullable!string infile = Nullable!string(),
                        Nullable!uint lineno=Nullable!uint())
    {
        if (infile.isNull)
            infile = this.infile;
        if (lineno.isNull)
            lineno = this.lineno;
        return "\"%s\", line %d: ".format(infile, lineno);
    }
}

string[] split(string s, Shlex.Comments comments = No.comments, Shlex.Posix posix = Yes.posix) {
    scope Shlex lex = Shlex(s, Nullable!string(), posix); // TODO: shorten
    lex.whitespaceSplit = true;
    if (!comments)
        lex.commenters = "";
    return lex.array;
}

unittest {
    import core.sys.posix.sys.resource;
    auto limit = rlimit(100*1000000, 100*1000000);
    setrlimit(RLIMIT_AS, &limit); // prevent OS crash due out of memory

    assert(split("") == []);
    assert(split("l") == ["l"]);
    assert(split("ls") == ["ls"]);
    assert(split("ls -l 'somefile; ls -xz ~'") == ["ls", "-l", "somefile; ls -xz ~"]);
    assert(split("ssh home 'somefile; ls -xz ~'") == ["ssh", "home", "somefile; ls -xz ~"]);
}

private immutable _findUnsafe = regex(r"[^[a-zA-Z0-9]@%+=:,./-]");

/** Return a shell-escaped version of the string *s*. */
string quote(string s) {
    if (s.empty)
        return "''";
    if (!matchFirst(s, _findUnsafe))
        return s;

    // use single quotes, and put single quotes into double quotes
    // the string $'b is then quoted as '$'"'"'b'
    return '\'' ~ s.replace("'", "'\"'\"'") ~ '\'';
}

unittest {
    assert(quote("") == "''");
    assert(quote("somefile; ls -xz ~") == "'somefile; ls -xz ~'");
    writeln(quote("'") == "''\"'\"''"); // TODO: Too long result (as inherited from the Python library)
}

void _printTokens(Shlex lexer) {
    while (true) {
        Nullable!string tt = lexer.getToken();
        if (tt.isNull || tt.empty) break; // TODO: can simplify?
        writeln("Token: " ~ tt);
    }
}

