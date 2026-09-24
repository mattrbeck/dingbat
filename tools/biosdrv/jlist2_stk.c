// jlist2.c through bd_callfn_stk: what each function leaves on the stack
// below the caller's sp (its pushes), and r6-r11 after it
#include "drv.h"
#define CALLFN(f, a, b, c) do { bd_callfn_stk(f, a, b, c); \
    for (u32 i_ = 0; i_ < 22; i_++) RESULT[8 + i_] = bd_stk[i_]; } while (0)
#include "jlist2.c"
