using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;

namespace DrawBot.Tests
{
    public sealed class AssertionFailed : Exception { public AssertionFailed(string m) : base(m) { } }

    /// <summary>Just enough of a test framework: every public void method named Test* of a class named *Tests runs.</summary>
    public static class Assert
    {
        static string Where(string file, int line) => " (" + System.IO.Path.GetFileName(file) + ":" + line + ")";

        public static void True(bool c, string msg = "", [CallerFilePath] string f = "", [CallerLineNumber] int l = 0)
        { if (!c) throw new AssertionFailed("expected true. " + msg + Where(f, l)); }

        public static void False(bool c, string msg = "", [CallerFilePath] string f = "", [CallerLineNumber] int l = 0)
        { if (c) throw new AssertionFailed("expected false. " + msg + Where(f, l)); }

        public static void Equal<T>(T expected, T actual, string msg = "", [CallerFilePath] string f = "", [CallerLineNumber] int l = 0)
        {
            if (!EqualityComparer<T>.Default.Equals(expected, actual))
                throw new AssertionFailed("expected " + Show(expected) + ", got " + Show(actual) + ". " + msg + Where(f, l));
        }

        public static void Seq<T>(IEnumerable<T> expected, IEnumerable<T> actual, string msg = "", [CallerFilePath] string f = "", [CallerLineNumber] int l = 0)
        {
            var e = expected.ToList(); var a = actual.ToList();
            if (!e.SequenceEqual(a))
                throw new AssertionFailed("expected [" + string.Join(", ", e.Select(x => Show(x))) + "], got [" + string.Join(", ", a.Select(x => Show(x))) + "]. " + msg + Where(f, l));
        }

        public static void Near(double expected, double actual, double accuracy, string msg = "", [CallerFilePath] string f = "", [CallerLineNumber] int l = 0)
        {
            if (!(Math.Abs(expected - actual) <= accuracy))
                throw new AssertionFailed("expected " + expected + " ± " + accuracy + ", got " + actual + ". " + msg + Where(f, l));
        }

        public static void Less(double a, double b, string msg = "", [CallerFilePath] string f = "", [CallerLineNumber] int l = 0)
        { if (!(a < b)) throw new AssertionFailed("expected " + a + " < " + b + ". " + msg + Where(f, l)); }

        public static void LessOrEqual(double a, double b, string msg = "", [CallerFilePath] string f = "", [CallerLineNumber] int l = 0)
        { if (!(a <= b)) throw new AssertionFailed("expected " + a + " ≤ " + b + ". " + msg + Where(f, l)); }

        public static void Fail(string msg, [CallerFilePath] string f = "", [CallerLineNumber] int l = 0) => throw new AssertionFailed(msg + Where(f, l));

        static string Show(object o) => o == null ? "null" : o.ToString();
    }

    public static class TestMain
    {
        public static int Main(string[] args)
        {
            DrawBot.App.Startup.Init();
            var filter = args.FirstOrDefault();
            var types = typeof(TestMain).Assembly.GetTypes().Where(t => t.Namespace == "DrawBot.Tests" && t.Name.EndsWith("Tests") && !t.IsAbstract).OrderBy(t => t.Name);
            int passed = 0, failed = 0;
            var sw = Stopwatch.StartNew();
            foreach (var type in types)
            {
                foreach (var m in type.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly)
                                     .Where(m => m.Name.StartsWith("Test") && m.GetParameters().Length == 0).OrderBy(m => m.MetadataToken))
                {
                    var name = type.Name + "." + m.Name;
                    if (filter != null && !name.Contains(filter)) continue;
                    var t0 = sw.Elapsed;
                    try
                    {
                        m.Invoke(Activator.CreateInstance(type), null);
                        passed++;
                        Console.WriteLine("  ok   " + name + "  (" + (sw.Elapsed - t0).TotalMilliseconds.ToString("F0") + " ms)");
                    }
                    catch (TargetInvocationException e)
                    {
                        failed++;
                        var inner = e.InnerException;
                        Console.WriteLine("  FAIL " + name + ": " + (inner is AssertionFailed ? inner.Message : inner.ToString()));
                    }
                }
            }
            Console.WriteLine();
            Console.WriteLine((failed == 0 ? "All " + passed + " tests passed" : failed + " of " + (passed + failed) + " tests FAILED") + " in " + sw.Elapsed.TotalSeconds.ToString("F1") + " s.");
            return failed == 0 ? 0 : 1;
        }
    }
}
