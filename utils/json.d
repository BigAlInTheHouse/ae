/**
 * JSON encoding.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.utils.json;

import std.exception;
import std.string;
import std.traits;

import ae.utils.meta;
import ae.utils.textout;

// ************************************************************************

struct CustomJsonWriter(WRITER)
{
	/// You can set this to something to e.g. write to another buffer.
	WRITER output;

	void putString(string s)
	{
		// TODO: escape Unicode characters?

		output.put('"');
		auto start = s.ptr, p = start, end = start+s.length;

		while (p < end)
		{
			auto c = *p++;
			if (Escapes.escaped[c])
				output.put(start[0..p-start-1], Escapes.chars[c]),
				start = p;
		}

		output.put(start[0..p-start], '"');
	}

	void put(T)(T v)
	{
		static if (is(T == enum))
			put(to!string(v));
		else
		static if (is(T : string))
			putString(v);
		else
		static if (is(T : long))
			return .put(output, v);
		else
		static if (is(T U : U[]))
		{
			output.put('[');
			if (v.length)
			{
				put(v[0]);
				foreach (i; v[1..$])
				{
					output.put(",");
					put(i);
				}
			}
			output.put(']');
		}
		else
		static if (is(T==struct))
		{
			output.put('{');
			bool first = true;
			foreach (i, field; v.tupleof)
			{
				static if (!doSkipSerialize!(T, v.tupleof[i].stringof[2..$]))
				{
					if (!first)
						output.put(',');
					else
						first = false;
					put(v.tupleof[i].stringof[2..$]);
					output.put(':');
					put(field);
				}
			}
			output.put('}');
		}
		else
		static if (isAssociativeArray!T)
		{
			output.put('{');
			bool first = true;
			foreach (key, value; v)
			{
				if (!first)
					output.put(',');
				else
					first = false;
				put(key);
				output.put(':');
				put(value);
			}
			output.put('}');
		}
		else
		static if (is(typeof(*v)))
			put(*v);
		else
			static assert(0, "Can't serialize " ~ T.stringof ~ " to JSON");
	}
}

alias CustomJsonWriter!StringBuilder JsonWriter;

private struct Escapes
{
	static __gshared string[256] chars;
	static __gshared bool[256] escaped;

	shared static this()
	{
		import std.string;

		escaped[] = true;
		foreach (c; 0..256)
			if (c=='\\')
				chars[c] = `\\`;
			else
			if (c=='\"')
				chars[c] = `\"`;
			else
			if (c=='\b')
				chars[c] = `\b`;
			else
			if (c=='\f')
				chars[c] = `\f`;
			else
			if (c=='\n')
				chars[c] = `\n`;
			else
			if (c=='\r')
				chars[c] = `\r`;
			else
			if (c=='\t')
				chars[c] = `\t`;
			else
			if (c<'\x20' || c == '\x7F' || c=='<' || c=='>' || c=='&')
				chars[c] = format(`\u%04x`, c);
			else
				chars[c] = [cast(char)c],
				escaped[c] = false;
	}
}

// ************************************************************************

string toJson(T)(T v)
{
	JsonWriter writer;
	writer.put(v);
	return writer.output.get();
}

unittest
{
	struct X { int a; string b; }
	X x = {17, "aoeu"};
	assert(toJson(x) == `{"a":17,"b":"aoeu"}`);
	int[] arr = [1,5,7];
	assert(toJson(arr) == `[1,5,7]`);
}

// ************************************************************************

import std.ascii;
import std.utf;
import std.conv;

import ae.utils.text;

private struct JsonParser
{
	string s;
	int p;

	char next()
	{
		enforce(p < s.length);
		return s[p++];
	}

	string readN(uint n)
	{
		string r;
		for (int i=0; i<n; i++)
			r ~= next();
		return r;
	}

	char peek()
	{
		enforce(p < s.length);
		return s[p];
	}

	void skipWhitespace()
	{
		while (isWhite(peek()))
			p++;
	}

	void expect(char c)
	{
		enforce(next()==c, c ~ " expected");
	}

	T read(T)()
	{
		static if (is(T==enum))
			return readEnum!(T)();
		else
		static if (is(T==string))
			return readString();
		else
		static if (is(T==bool))
			return readBool();
		else
		static if (is(T : long))
			return readInt!(T)();
		else
		static if (is(T U : U[]))
			return readArray!(U)();
		else
		static if (is(T==struct))
			return readObject!(T)();
		else
		static if (is(typeof(T.init.keys)) && is(typeof(T.init.values)) && is(typeof(T.init.keys[0])==string))
			return readAA!(T)();
		else
		static if (is(T U : U*))
			return readPointer!(U)();
		else
			static assert(0, "Can't decode " ~ T.stringof ~ " from JSON");
	}

	string readString()
	{
		skipWhitespace();
		expect('"');
		string result;
		while (true)
		{
			auto c = next();
			if (c=='"')
				break;
			else
			if (c=='\\')
				switch (next())
				{
					case '"':  result ~= '"'; break;
					case '/':  result ~= '/'; break;
					case '\\': result ~= '\\'; break;
					case 'b':  result ~= '\b'; break;
					case 'f':  result ~= '\f'; break;
					case 'n':  result ~= '\n'; break;
					case 'r':  result ~= '\r'; break;
					case 't':  result ~= '\t'; break;
					case 'u':  result ~= toUTF8([cast(wchar)fromHex!ushort(readN(4))]); break;
					default: enforce(false, "Unknown escape");
				}
			else
				result ~= c;
		}
		return result;
	}

	bool readBool()
	{
		skipWhitespace();
		if (peek()=='t')
		{
			enforce(readN(4) == "true", "Bad boolean");
			return true;
		}
		else
		{
			enforce(readN(5) == "false", "Bad boolean");
			return false;
		}
	}

	T readInt(T)()
	{
		skipWhitespace();
		T v;
		string s;
		char c;
		while (c=peek(), c=='-' || (c>='0' && c<='9'))
			s ~= c, p++;
		static if (is(T==byte))
			return to!byte(s);
		else
		static if (is(T==ubyte))
			return to!ubyte(s);
		else
		static if (is(T==short))
			return to!short(s);
		else
		static if (is(T==ushort))
			return to!ushort(s);
		else
		static if (is(T==int))
			return to!int(s);
		else
		static if (is(T==uint))
			return to!uint(s);
		else
		static if (is(T==long))
			return to!long(s);
		else
		static if (is(T==ulong))
			return to!ulong(s);
		else
			static assert(0, "Don't know how to parse numerical type " ~ T.stringof);
	}

	T[] readArray(T)()
	{
		skipWhitespace();
		expect('[');
		skipWhitespace();
		T[] result;
		if (peek()==']')
		{
			p++;
			return result;
		}
		while(true)
		{
			result ~= read!(T)();
			skipWhitespace();
			if (peek()==']')
			{
				p++;
				return result;
			}
			else
				expect(',');
		}
	}

	T readObject(T)()
	{
		skipWhitespace();
		expect('{');
		skipWhitespace();
		T v;
		if (peek()=='}')
		{
			p++;
			return v;
		}

		while (true)
		{
			string jsonField = readString();
			skipWhitespace();
			expect(':');

			bool found;
			foreach (i, field; v.tupleof)
				if (v.tupleof[i].stringof[2..$] == jsonField)
				{
					v.tupleof[i] = read!(typeof(v.tupleof[i]))();
					found = true;
					break;
				}
			enforce(found, "Unknown field " ~ jsonField);

			skipWhitespace();
			if (peek()=='}')
			{
				p++;
				return v;
			}
			else
				expect(',');
		}
	}

	T readAA(T)()
	{
		skipWhitespace();
		expect('{');
		skipWhitespace();
		T v;
		if (peek()=='}')
		{
			p++;
			return v;
		}

		while (true)
		{
			string jsonField = readString();
			skipWhitespace();
			expect(':');

			v[jsonField] = read!(typeof(v.values[0]))();

			skipWhitespace();
			if (peek()=='}')
			{
				p++;
				return v;
			}
			else
				expect(',');
		}
	}

	T readEnum(T)()
	{
		return to!T(readString());
	}
}

T jsonParse(T)(string s) { return JsonParser(s).read!T(); }

unittest
{
	struct S { int i; S[] arr; }
	S s = S(42, [S(1), S(2)]);
	auto s2 = jsonParse!S(toJson(s));
	//assert(s == s2); // Issue 3789
	assert(s.i == s2.i && s.arr == s2.arr);
}

// ************************************************************************

/**
 * A template that designates fields which should not be serialized to Json.
 *
 * Example:
 * ---
 * struct Point { int x, y, z; mixin NonSerialized!(x, z); }
 * assert(jsonParse!Point(toJson(Point(1, 2, 3))) == Point(0, 2, 0));
 * ---
 */
template NonSerialized(fields...)
{
	mixin(NonSerializedFields(toArray!fields()));
}

private string NonSerializedFields(string[] fields)
{
	string result;
	foreach (field; fields)
		result ~= "enum bool " ~ field ~ "_nonSerialized = 1;";
	return result;
}

private template doSkipSerialize(T, string member)
{
	enum bool doSkipSerialize = __traits(hasMember, T, member ~ "_nonSerialized");
}

unittest
{
	struct Point { int x, y, z; mixin NonSerialized!(x, z); }
	assert(jsonParse!Point(toJson(Point(1, 2, 3))) == Point(0, 2, 0));
}

unittest
{
	enum En { one, two }
	struct S { int i1, i2; S[] arr1, arr2; string[string] dic; En en; mixin NonSerialized!(i2, arr2); }
	S s = S(42, 5, [S(1), S(2)], [S(3), S(4)], ["apple":"fruit", "pizza":"vegetable"], En.two);
	auto s2 = jsonParse!S(toJson(s));
	assert(s.i1 == s2.i1 && s2.i2 is int.init && s.arr1 == s2.arr1 && s2.arr2 is null && s.dic == s2.dic && s.en == En.two);
}
