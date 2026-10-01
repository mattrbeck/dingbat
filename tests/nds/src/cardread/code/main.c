// cardread: DS card (slot-1) reads through calico's ntrcard driver, by CPU
// and by slot-1 DMA, checked against data the boot already put in RAM.
// Prints one PASS/FAIL line per check on the bottom-screen console.
//
//   arm7     0x200 bytes of the ARM7 binary at an unaligned offset (CPU)
//            == RAM at its load address (calico's ARM7 crt0 runs in place,
//            so its first bytes are never overwritten)
//   dma      the same by slot-1 DMA
//   low      sector 0 (main mode: reads below 0x8000 come from
//            0x8000 + (addr & 0x1FF), GBATEK) == sector 0x8000
//   multi    16 sectors by DMA == the same 16 sectors by CPU
//   chipid   the chip ID == the one the boot left at 0x02FFFC00

#include <nds.h>
#include <stdio.h>
#include <string.h>

static u8 buf_a[0x2000] __attribute__((aligned(32)));
static u8 buf_b[0x2000] __attribute__((aligned(32)));

static void check(const char* name, bool ok)
{
	iprintf("%-8s %s\n", name, ok ? "PASS" : "FAIL");
}

int main(void)
{
	consoleDemoInit();
	iprintf("cardread\n");

	const u8* header = (const u8*)0x02FFFE00;
	u32 arm7_rom = *(const u32*)(header + 0x30);
	u32 arm7_ram = *(const u32*)(header + 0x38);

	if (!ntrcardOpen()) {
		iprintf("ntrcardOpen FAIL\n");
	} else {
		iprintf("mode %d\n", (int)ntrcardGetMode());

		memset(buf_a, 0, sizeof(buf_a));
		bool ok = ntrcardRomRead(-1, arm7_rom + 4, buf_a, 0x200);
		check("arm7", ok && memcmp(buf_a, (const u8*)arm7_ram + 4, 0x200) == 0);

		memset(buf_a, 0, sizeof(buf_a));
		ok = ntrcardRomRead(3, arm7_rom + 4, buf_a, 0x200);
		check("dma", ok && memcmp(buf_a, (const u8*)arm7_ram + 4, 0x200) == 0);

		ok = ntrcardRomReadSector(3, 0, buf_a);
		bool ok2 = ntrcardRomReadSector(3, 0x8000, buf_b);
		check("low", ok && ok2 && memcmp(buf_a, buf_b, 0x200) == 0);

		ok = ntrcardRomRead(3, 0x8000, buf_a, 0x2000);
		ok2 = ntrcardRomRead(-1, 0x8000, buf_b, 0x2000);
		check("multi", ok && ok2 && memcmp(buf_a, buf_b, 0x2000) == 0);

		NtrChipId id;
		ok = ntrcardGetChipId(&id);
		u32 raw;
		memcpy(&raw, &id, 4);
		check("chipid", ok && raw == *(const u32*)0x02FFFC00);
		iprintf("chip %08lX\n", raw);
		ntrcardClose();
	}
	iprintf("done\n");

	while (pmMainLoop()) {
		swiWaitForVBlank();
	}
	return 0;
}
