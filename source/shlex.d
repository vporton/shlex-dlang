module shlex;

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
import std.string;

// FIXME: camelCase

alias ShlexStream = InputRange!dchar; // Unicode stream

private void skipLine(ShlexStream stream) {
    while (!stream.empty && stream.front == '\n'd) stream.popFront();
}

/// A lexical analyzer class for simple shell-like syntaxes
struct Shlex {
    alias Posix = Flag!"posix";
    alias PunctuationChars = Flag!"punctuationChars";

private:
    // TODO: Python shlex has some of the following as public instance variables (also check visibility of member functions)
    ShlexStream instream;
    Nullable!string infile;
    Posix posix;
    delegate isEof(string token);
    string wordchars;
    static immutable whitespace = " \t\r\n";
    bool whitespace_split = false;
    static immutable quotes = "'\"";
    static immutable escape = '\\'; // TODO: char or string?
    static immutable escapedquotes = '"'; // TODO: char or string?
    char state = ' '; // TODO: Should be an enum instead, also support None
    auto pushback = DList!string(); // may be not the fastest
    uint lineno;
    ubyte debug_ = 0;
    string token = "";
    auto filestack = DList!(Tuple(Nullable!string, ShlexStream, uint))(); // may be not the fastest
    Nullable!string source; // TODO: Represent no source just as an empty string?
    string punctuation_chars;
    // _pushback_chars is a push back queue used by lookahead logic
    auto _pushback_chars = DList(); // may be not the fastest

public:
    this(Stream)(Stream instream,
                 Nullable!string infile = Nullable!string(),
                 Posix posix = No.posix,
                 PunctuationChars punctuation_chars = No.punctuationChars)
    {
        this(inputRangeObject(instream), infile, posix, punctuation_chars);
    }

    /** We don't support implicit stdin as `instream` as in Python. */
    this(ShlexStream instream,
         Nullable!string infile = Nullable!string(),
         Posix posix = No.posix,
         PunctuationChars punctuation_chars = No.punctuationChars)
    {
        this.instream = instream;
        this.infile = infile;
        this.posix = posix;
        isEof = posix ? (string) => false ? (string s) => s.empty;
        // TODO: remove commented code
        //if posix:
        //    self.eof = None
        //else:
        //    self.eof = ''
        //self.commenters = '#'
        wordchars = "abcdfeghijklmnopqrstuvwxyz" ~ "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_";
        if (posix)
            wordchars ~= "ßàáâãäåæçèéêëìíîïðñòóôõöøùúûüýþÿ" ~ "ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝÞ";
        lineno = 1
        this.punctuation_chars = punctuation_chars ? "();<>|&" : "";
        if (punctuation_chars) {
            // these chars added because allowed in file names, args, wildcards
            wordchars ~= '~-./*?='
            // remove any punctuation chars from wordchars // TODO: https://stackoverflow.com/q/54467991/856090
            t = self.wordchars.maketrans(dict.fromkeys(punctuation_chars))
            self.wordchars = self.wordchars.translate(t)
        }
    }

    /** Push a token onto the stack popped by the get_token method */
    void push_token(tok) {
        if (debug_ >= 1)
            writeln("shlex: pushing token " ~ tok); // FIXME: need toString?
        pushback.insertFront(tok);
    }

    /** Push an input source onto the lexer's input source stack. */
    void push_source(Stream)(Stream newstream, Nullable!string newfile = Nullable!string()) {
        push_source(inputRangeObject(instream), newfile);
    }

    /** Push an input source onto the lexer's input source stack. */
    void push_source(ShlexStream newstream, Nullable!string newfile = Nullable!string()) {
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
    void pop_source() {
        (cast(File)instream).close(); // a little messy
        // use a tuple library?
        immutable t = filestack.popFirstOf();
        infile   = t[0];
        instream = t[1];
        lineno   = t[2];
        if (debug_)
            writeln("shlex: popping to %s, line %d".format(instream, lineno));
        state = ' ';
    }

    // TODO: Use empty string for None?
    /** Get a token from the input stream (or from stack if it's nonempty) */
    string get_token() {
        if (!pushback.empty) {
            immutable tok = pushback.popFirstOf();
            if (debug_ >= 1)
                writeln("shlex: popping token " ~ tok);
            return tok;
        }
        // No pushback.  Get a token.
        Nullable!string raw = read_token();
        // Handle inclusions
        if (!source.empty) {
            while (raw == source) {
                immutable spec = sourcehook(read_token());
                if (!spec.empty) {
                    immutable newfile   = spec[0];
                    immutable newstream = spec[1];
                    push_source(newstream, newfile);
                }
                raw = get_token();
            }
        }
        // Maybe we got EOF instead?
        while isEof(raw) {
            if (filestack.empty)
                return self.eof; // FIXME
            else {
                pop_source()
                raw = get_token();
            }
        }
        // Neither inclusion nor EOF
        if (debug_ >= 1) {
            if (!isEof(raw))
                print("shlex: token=" ~ raw);
            else
                print("shlex: token=EOF");
        }
        return raw;
    }

    def read_token(self):
        quoted = False
        escapedstate = ' '
        while True:
            if self.punctuation_chars and self._pushback_chars:
                nextchar = self._pushback_chars.pop()
            else:
                nextchar = self.instream.read(1)
            if nextchar == '\n':
                self.lineno += 1
            if self.debug >= 3:
                print("shlex: in state %r I see character: %r" % (self.state,
                                                                  nextchar))
            if self.state is None:
                self.token = ''        # past end of file
                break
            elif self.state == ' ':
                if not nextchar:
                    self.state = None  # end of file
                    break
                elif nextchar in self.whitespace:
                    if self.debug >= 2:
                        print("shlex: I see whitespace in whitespace state")
                    if self.token or (self.posix and quoted):
                        break   # emit current token
                    else:
                        continue
                elif nextchar in self.commenters:
                    self.instream.readline()
                    self.lineno += 1
                elif self.posix and nextchar in self.escape:
                    escapedstate = 'a'
                    self.state = nextchar
                elif nextchar in self.wordchars:
                    self.token = nextchar
                    self.state = 'a'
                elif nextchar in self.punctuation_chars:
                    self.token = nextchar
                    self.state = 'c'
                elif nextchar in self.quotes:
                    if not self.posix:
                        self.token = nextchar
                    self.state = nextchar
                elif self.whitespace_split:
                    self.token = nextchar
                    self.state = 'a'
                else:
                    self.token = nextchar
                    if self.token or (self.posix and quoted):
                        break   # emit current token
                    else:
                        continue
            elif self.state in self.quotes:
                quoted = True
                if not nextchar:      # end of file
                    if self.debug >= 2:
                        print("shlex: I see EOF in quotes state")
                    # XXX what error should be raised here?
                    raise ValueError("No closing quotation")
                if nextchar == self.state:
                    if not self.posix:
                        self.token += nextchar
                        self.state = ' '
                        break
                    else:
                        self.state = 'a'
                elif (self.posix and nextchar in self.escape and self.state
                      in self.escapedquotes):
                    escapedstate = self.state
                    self.state = nextchar
                else:
                    self.token += nextchar
            elif self.state in self.escape:
                if not nextchar:      # end of file
                    if self.debug >= 2:
                        print("shlex: I see EOF in escape state")
                    # XXX what error should be raised here?
                    raise ValueError("No escaped character")
                # In posix shells, only the quote itself or the escape
                # character may be escaped within quotes.
                if (escapedstate in self.quotes and
                        nextchar != self.state and nextchar != escapedstate):
                    self.token += self.state
                self.token += nextchar
                self.state = escapedstate
            elif self.state in ('a', 'c'):
                if not nextchar:
                    self.state = None   # end of file
                    break
                elif nextchar in self.whitespace:
                    if self.debug >= 2:
                        print("shlex: I see whitespace in word state")
                    self.state = ' '
                    if self.token or (self.posix and quoted):
                        break   # emit current token
                    else:
                        continue
                elif nextchar in self.commenters:
                    self.instream.readline()
                    self.lineno += 1
                    if self.posix:
                        self.state = ' '
                        if self.token or (self.posix and quoted):
                            break   # emit current token
                        else:
                            continue
                elif self.state == 'c':
                    if nextchar in self.punctuation_chars:
                        self.token += nextchar
                    else:
                        if nextchar not in self.whitespace:
                            self._pushback_chars.append(nextchar)
                        self.state = ' '
                        break
                elif self.posix and nextchar in self.quotes:
                    self.state = nextchar
                elif self.posix and nextchar in self.escape:
                    escapedstate = 'a'
                    self.state = nextchar
                elif (nextchar in self.wordchars or nextchar in self.quotes
                      or self.whitespace_split):
                    self.token += nextchar
                else:
                    if self.punctuation_chars:
                        self._pushback_chars.append(nextchar)
                    else:
                        self.pushback.appendleft(nextchar)
                    if self.debug >= 2:
                        print("shlex: I see punctuation in word state")
                    self.state = ' '
                    if self.token or (self.posix and quoted):
                        break   # emit current token
                    else:
                        continue
        result = self.token
        self.token = ''
        if self.posix and not quoted and result == '':
            result = None
        if self.debug > 1:
            if result:
                print("shlex: raw token=" + repr(result))
            else:
                print("shlex: raw token=EOF")
        return result

    def sourcehook(self, newfile):
        "Hook called on a filename to be sourced."
        if newfile[0] == '"':
            newfile = newfile[1:-1]
        # This implements cpp-like semantics for relative-path inclusion.
        if isinstance(self.infile, str) and not os.path.isabs(newfile):
            newfile = os.path.join(os.path.dirname(self.infile), newfile)
        return (newfile, open(newfile, "r"))

    def error_leader(self, infile=None, lineno=None):
        "Emit a C-compiler-like, Emacs-friendly error-message leader."
        if infile is None:
            infile = self.infile
        if lineno is None:
            lineno = self.lineno
        return "\"%s\", line %d: " % (infile, lineno)

    def __iter__(self):
        return self

    def __next__(self):
        token = self.get_token()
        if token == self.eof:
            raise StopIteration
        return token

def split(s, comments=False, posix=True):
    lex = shlex(s, posix=posix)
    lex.whitespace_split = True
    if not comments:
        lex.commenters = ''
    return list(lex)


_find_unsafe = re.compile(r'[^\w@%+=:,./-]', re.ASCII).search

def quote(s):
    """Return a shell-escaped version of the string *s*."""
    if not s:
        return "''"
    if _find_unsafe(s) is None:
        return s

    # use single quotes, and put single quotes into double quotes
    # the string $'b is then quoted as '$'"'"'b'
    return "'" + s.replace("'", "'\"'\"'") + "'"


def _print_tokens(lexer):
    while 1:
        tt = lexer.get_token()
        if not tt:
            break
        print("Token: " + repr(tt))

if __name__ == '__main__':
    if len(sys.argv) == 1:
        _print_tokens(shlex())
    else:
        fn = sys.argv[1]
        with open(fn) as f:
            _print_tokens(shlex(f, fn))

