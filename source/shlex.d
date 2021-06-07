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
import std.container;
import std.container.dlist;
import std.algorithm;
import std.file;
import std.path;
import std.stdio : write, writeln;
import pure_dependency.providers;
import struct_params;

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
    alias PunctuationChars = Flag!"PunctuationChars";
    alias Comments = Flag!"comments";

private:
    ShlexStream instream;
    Nullable!string infile;
    Posix posix;
    Nullable!string eof; // seems not efficient
    //bool delegate(string token) isEof;
    auto commenters = new RedBlackTree!(immutable dchar)("#");
    RedBlackTree!(immutable dchar) wordchars;
    static immutable whitespace = new RedBlackTree!(immutable dchar)(" \t\r\n");
    bool whitespaceSplit = false;
    static immutable quotes = new RedBlackTree!(immutable dchar)("'\"");
    static immutable escape = new RedBlackTree!(immutable dchar)("\\"); // char or string?
    static immutable escapedquotes = new RedBlackTree!(immutable dchar)("\""); // char or string?
    Nullable!dchar state = ' '; // a little inefficient?
    auto pushback = DList!string(); // may be not the fastest
    uint lineno;
    ubyte debug_ = 0;
    string token = "";
    auto filestack = DList!(Tuple!(Nullable!string, ShlexStream, uint))(); // may be not the fastest
    Nullable!string source; // TODO: Represent no source just as an empty string?
    auto punctuationChars = new RedBlackTree!(immutable dchar)();
    // _pushbackChars is a push back queue used by lookahead logic
    auto _pushbackChars = DList!dchar(); // may be not the fastest

public:
    @disable this();

    /** We don't support implicit stdin as `instream` as in Python. */
    this(ShlexStream instream,
         Nullable!string infile = Nullable!string.init,
         Posix posix = No.posix,
         PunctuationChars punctuationCharsFlag = No.PunctuationChars,
         bool whitespaceSplit = false)
    {
        this.instream = instream;
        this.infile = infile;
        this.posix = posix;
        this.whitespaceSplit = whitespaceSplit;
        if (!posix) eof = "";
        wordchars = new RedBlackTree!(immutable dchar)("abcdfeghijklmnopqrstuvwxyz" ~ "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_");
        if (posix)
            wordchars.stableInsert("ßàáâãäåæçèéêëìíîïðñòóôõöøùúûüýþÿ" ~ "ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝÞ");
        lineno = 1;
        if(punctuationCharsFlag)
            this.punctuationChars.stableInsert("();<>|&");
        if (punctuationCharsFlag) {
            // these chars added because allowed in file names, args, wildcards
            wordchars.stableInsert("~-./*?=");
            // remove any punctuation chars from wordchars
            // TODO: Isn't it better to use dstring?
            wordchars = new RedBlackTree!(immutable dchar)(filter!(c => c !in punctuationChars)(wordchars.array));
        }
    }

    this(Stream)(Stream instream,
                 Nullable!string infile = Nullable!string.init,
                 Posix posix = No.posix,
                 PunctuationChars punctuationChars = No.PunctuationChars,
                 bool whitespaceSplit = false)
    {
        import std.conv;
        // TODO: Inefficient to convert to dstring in memory.
        this(cast (ShlexStream)inputRangeObject(cast (const dchar[])instream.dtext), infile, posix, punctuationChars, whitespaceSplit);
    }

    void dump() {
        if (debug_ >= 3) {
//            writeln("state='", state, "\' nextchar='", nextchar, "\' token='", token, '\'');
            writeln("state='", state.get(), "\' token='", token, '\'');
        }
    }

    /** Push a token onto the stack popped by the getToken method */
    void pushToken(string tok) {
        if (debug_ >= 1)
            writeln("shlex: pushing token " ~ tok);
        pushback.insertFront(tok);
    }

    /** Push an input source onto the lexer's input source stack. */
    void pushSource(Stream)(Stream newstream, Nullable!string newfile = Nullable!string.init) {
        pushSource(inputRangeObject(instream), newfile);
    }

    /** Push an input source onto the lexer's input source stack. */
    void pushSource(ShlexStream newstream, Nullable!string newfile = Nullable!string.init) {
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
        if (!source.isNull && !source.get().empty) {
            while (raw == source) {
                auto spec = sourcehook(readToken().get());
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
                writeln("shlex: token=" ~ raw.get);
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
                writeln("shlex: in state %s I see character: s".format(state.get(), nextchar));
            if (state.isNull) {
                // TODO: Debugger shows that this is never reached. Is this code needed?
                token = "";        // past end of file
                break;
            } else if (state.get() == ' ') {
                if (nextchar.isNull) {
                    state.nullify();  // end of file
                    break;
                } else if (nextchar.get in whitespace) {
                    if (debug_ >= 2)
                        writeln("shlex: I see whitespace in whitespace state");
                    if ((token && !token.empty) || (posix && quoted))
                        break;   // emit current token
                    else
                        continue;
                } else if (nextchar.get in commenters) {
                    instream.skipLine();
                    ++lineno;
                } else if (posix && nextchar.get in escape) {
                    escapedstate = 'a';
                    state = nextchar.get();
                } else if (nextchar.get in wordchars) {
                    token = [nextchar.get].toUTF8;
                    state = 'a';
                } else if (nextchar.get in punctuationChars) {
                    token = [nextchar.get].toUTF8;
                    state = 'c';
                } else if (nextchar.get in quotes) {
                    if (!posix) token = [nextchar.get].toUTF8;
                    state = nextchar.get();
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
            } else if (!state.isNull && state.get() in quotes) {
                quoted = true;
                if (nextchar.isNull) {      // end of file
                    if (debug_ >= 2)
                        writeln("shlex: I see EOF in quotes state");
                    // XXX what error should be raised here?
                    throw new Exception("No closing quotation");
                }
                if (nextchar.get() == state.get()) {
                    if (!posix) {
                        token ~= nextchar.get();
                        state = ' ';
                        break;
                    } else
                        state = 'a';
                } else if (posix && !nextchar.isNull && nextchar.get in escape &&
                        !state.isNull && state.get in escapedquotes) {
                    escapedstate = state.get();
                    state = nextchar.get();
                } else
                    token ~= nextchar.get();
            } else if (!state.isNull && state.get() in escape) {
                if (nextchar.isNull) {      // end of file
                    if (debug_ >= 2)
                        writeln("shlex: I see EOF in escape state");
                    // XXX what error should be raised here?
                    throw new Exception("No escaped character");
                }
                // In posix shells, only the quote itself or the escape
                // character may be escaped within quotes.
                if (escapedstate in quotes && nextchar.get() != state.get() && nextchar.get() != escapedstate)
                    token ~= state.get();
                token ~= nextchar.get();
                state = escapedstate;
            } else if (!state.isNull && (state.get == 'a' || state.get == 'c')) {
                if (nextchar.isNull) {
                    state.nullify();   // end of file
                    break;
                } else if (nextchar.get in whitespace) {
                    if (debug_ >= 2)
                        writeln("shlex: I see whitespace in word state");
                    state = ' ';
                    if (token || (posix && quoted))
                        break;   // emit current token
                    else
                        continue;
                } else if (nextchar.get in commenters) {
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
                    if (nextchar.get in punctuationChars)
                        token ~= nextchar.get();
                    else {
                        if (!nextchar.get in whitespace)
                            _pushbackChars.insertBack(nextchar.get());
                        state = ' ';
                        break;
                    }
                } else if (posix && nextchar.get in quotes)
                    state = nextchar.get();
                else if (posix && nextchar.get in escape) {
                    escapedstate = 'a';
                    state = nextchar.get();
                } else if (nextchar.get in wordchars || nextchar.get in quotes || whitespaceSplit) {
                    token ~= nextchar.get();
                } else {
                    if (punctuationChars.empty)
                        pushback.insertFront(nextchar.get.to!string);
                    else
                        _pushbackChars.insertBack(nextchar.get());
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
            if (!result.isNull && !result.get().empty) // TODO: can simplify?
                writeln("shlex: raw token=" ~ result.get);
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
            newfile = buildPath(dirName(infile.get()), newfile);
        return tuple(newfile, new ShlexFile(newfile));
    }

    /** Emit a C-compiler-like, Emacs-friendly error-message leader. */
    string errorLeader(Nullable!string infile = Nullable!string.init,
                        Nullable!uint lineno=Nullable!uint.init)
    {
        if (infile.isNull)
            infile = this.infile;
        if (lineno.isNull)
            lineno = this.lineno;
        return "\"%s\", line %d: ".format(infile, lineno);
    }
}

mixin StructParams!("ShlexParams",
                    ShlexStream, "instream",
                    Nullable!string, "infile",
                    Shlex.Posix, "posix",
                    Shlex.PunctuationChars, "punctuationCharsFlag",
                    bool, "whitespaceSplit");
private ShlexParams.WithDefaults shlexDefaults = { infile: Nullable!string.init,
                                                   posix: No.posix,
                                                   punctuationCharsFlag: No.PunctuationChars,
                                                   whitespaceSplit: false };
alias ShlexProvider = ProviderWithDefaults!(Callable!(
    (ShlexStream instream, Nullable!string infile,
     Shlex.Posix posix,
     Shlex.PunctuationChars punctuationCharsFlag,
     bool whitespaceSplit) => new Shlex(instream, infile, posix, punctuationCharsFlag, whitespaceSplit)),
    ShlexParams, shlexDefaults);

template ShlexProviderStream(Stream) {
    mixin StructParams!("ShlexParams",
                        Stream, "instream",
                        Nullable!string, "infile",
                        Shlex.Posix, "posix",
                        Shlex.PunctuationChars, "punctuationCharsFlag",
                        bool, "whitespaceSplit");
    private ShlexParams.WithDefaults shlexDefaults = { infile: Nullable!string.init,
                                                       posix: No.posix,
                                                       punctuationCharsFlag: No.PunctuationChars,
                                                       whitespaceSplit: false };
    alias ShlexProvider = ProviderWithDefaults!(Callable!(
        (Stream instream, Nullable!string infile,
         Shlex.Posix posix,
         Shlex.PunctuationChars punctuationCharsFlag,
        bool whitespaceSplit) => new Shlex(instream, infile, posix, punctuationCharsFlag, whitespaceSplit)),
    ShlexParams, shlexDefaults);
}

// TODO: Use dependency injection.
string[] split(string s, Shlex.Comments comments = No.comments, Shlex.Posix posix = Yes.posix) {
    scope Shlex lex = Shlex(s, Nullable!string.init, posix); // TODO: shorten
    lex.whitespaceSplit = true;
    if (!comments)
        lex.commenters.clear();
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
        if (tt.isNull || tt.get().empty) break; // TODO: can simplify?
        writeln("Token: " ~ tt.get);
    }
}

