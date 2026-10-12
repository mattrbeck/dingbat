// rusage PID... : the summed host instructions and cycles of those processes
// (macOS proc_pid_rusage), "INSTR CYCLES" (tools/ndswasm: cc -O2 -o rusage rusage.c)
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  unsigned long long ins = 0, cyc = 0;
  for (int i = 1; i < argc; i++) {
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(atoi(argv[i]), RUSAGE_INFO_V4, (rusage_info_t *)&ri) == 0) {
      ins += ri.ri_instructions;
      cyc += ri.ri_cycles;
    }
  }
  printf("%llu %llu\n", ins, cyc);
  return 0;
}
