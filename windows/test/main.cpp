/* The Windows shell's test runner.
 *
 * One entry per suite, in the order the shell reaches for them: what the
 * mariner types, then what the core hands over, then what the shell writes
 * down. Exit code 0 when every check passed.
 *
 * These cover the shell's MODEL — the parsers, the formatters, the geometry
 * and the store. The WinUI layer is not here: it needs a XAML host, and the
 * point of this target is that everything a host is not required for can be
 * run by anyone with the compiler the core already needs.
 */
#include <cstdio>

#include "lk_test.h"

void TestCoord();
void TestJson();
void TestUtf8();
void TestPick();
void TestLicenses();
void TestPluginRegistry();

int main()
{
    std::printf("lookout-marine: the Windows shell\n\n");

    TestCoord();
    TestJson();
    TestUtf8();
    TestPick();
    TestLicenses();
    TestPluginRegistry();

    return lktest::Report();
}
