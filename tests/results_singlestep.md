# SingleStepTests - Detailed Results

SingleStepTests/sm83 at `f9c3021` (every case) and SingleStepTests/ARM7TDMI at `e3097d8` (the first 2 MB of each file), run by `singlestep_test` on the CPU cores. A case passes when the final registers and memory and the bus sequence all agree; ARM7TDMI also scores each access's N/S type. Known divergences are failures where dingbat follows the console or the documentation, or the encoding is UNPREDICTABLE; tests/README.md, "SingleStepTests", gives the evidence for each.

## Game Boy - SingleStepTests SM83

| Row | Cases | Pass | State | Bus | Access | Known divergences |
|-----|-------|------|-------|-----|--------|-------------------|
| sm83/00-0F | 16000 | 16000 | 16000 | 16000 | 16000 |  |
| sm83/10-1F | 16000 | 15000 | 15000 | 15000 | 15000 | 1000 documented: STOP is two bytes with no interrupt pending |
| sm83/20-2F | 16000 | 16000 | 16000 | 16000 | 16000 |  |
| sm83/30-3F | 16000 | 16000 | 16000 | 16000 | 16000 |  |
| sm83/40-4F | 16000 | 16000 | 16000 | 16000 | 16000 |  |
| sm83/50-5F | 16000 | 16000 | 16000 | 16000 | 16000 |  |
| sm83/60-6F | 16000 | 16000 | 16000 | 16000 | 16000 |  |
| sm83/70-7F | 16000 | 15000 | 16000 | 15000 | 15000 | 1000 convention: HALT's halted M-cycles are not the instruction's |
| sm83/80-8F | 16000 | 16000 | 16000 | 16000 | 16000 |  |
| sm83/90-9F | 16000 | 16000 | 16000 | 16000 | 16000 |  |
| sm83/A0-AF | 16000 | 16000 | 16000 | 16000 | 16000 |  |
| sm83/B0-BF | 16000 | 16000 | 16000 | 16000 | 16000 |  |
| sm83/C0-CF | 15000 | 15000 | 15000 | 15000 | 15000 |  |
| sm83/CB 00-3F (rotate, shift, SWAP) | 64000 | 64000 | 64000 | 64000 | 64000 |  |
| sm83/CB 40-7F (BIT) | 64000 | 64000 | 64000 | 64000 | 64000 |  |
| sm83/CB 80-BF (RES) | 64000 | 64000 | 64000 | 64000 | 64000 |  |
| sm83/CB C0-FF (SET) | 64000 | 64000 | 64000 | 64000 | 64000 |  |
| sm83/D0-DF | 13000 | 13000 | 13000 | 13000 | 13000 |  |
| sm83/E0-EF | 11000 | 11000 | 11000 | 11000 | 11000 |  |
| sm83/F0-FF | 13000 | 13000 | 13000 | 13000 | 13000 |  |

## GBA - SingleStepTests ARM7TDMI

| Row | Cases | Pass | State | Bus | Access | Known divergences |
|-----|-------|------|-------|-----|--------|-------------------|
| arm7tdmi/arm_b_bl | 5035 | 5035 | 5035 | 5035 | 5035 |  |
| arm7tdmi/arm_bx | 5044 | 5044 | 5044 | 5044 | 5044 |  |
| arm7tdmi/arm_cdp | 5042 | 5042 | 5042 | 5042 | 5042 |  |
| arm7tdmi/arm_data_proc_immediate | 5334 | 5192 | 5192 | 5334 | 5334 | 119 unpredictable: test op with Rd = r15 (ARMv2 TSTP-style); 23 hardware: S-bit write to r15 in User/System keeps NZCV |
| arm7tdmi/arm_data_proc_immediate_shift | 5334 | 5195 | 5195 | 5334 | 5334 | 117 unpredictable: test op with Rd = r15 (ARMv2 TSTP-style); 22 hardware: S-bit write to r15 in User/System keeps NZCV |
| arm7tdmi/arm_data_proc_register_shift | 5331 | 5117 | 5117 | 5329 | 5329 | 128 unpredictable: test op with Rd = r15 (ARMv2 TSTP-style); 58 unpredictable: r15 as the shift register; 28 hardware: S-bit write to r15 in User/System keeps NZCV |
| arm7tdmi/arm_ldm_stm | 4249 | 4196 | 4196 | 4196 | 4196 | 53 hardware: no writeback to a base of r15 |
| arm7tdmi/arm_ldr_str_immediate_offset | 5167 | 5042 | 5042 | 5094 | 5094 | 125 hardware: r15 base writeback |
| arm7tdmi/arm_ldr_str_register_offset | 5167 | 5054 | 5054 | 5112 | 5112 | 113 hardware: r15 base writeback |
| arm7tdmi/arm_ldrh_strh | 5163 | 5163 | 5163 | 5163 | 5163 |  |
| arm7tdmi/arm_ldrsb_ldrsh | 5159 | 5159 | 5159 | 5159 | 5159 |  |
| arm7tdmi/arm_mcr_mrc | 5039 | 4861 | 4861 | 4861 | 4861 | 178 hardware: CP14 answers MRC/MCR |
| arm7tdmi/arm_mrs | 5349 | 5179 | 5179 | 5179 | 5179 | 170 unpredictable: MRS to r15 |
| arm7tdmi/arm_msr_imm | 5349 | 4891 | 4891 | 5349 | 5349 | 458 hardware: PSR bits 8-27 read 0, SPSR bit 4 reads 1 |
| arm7tdmi/arm_msr_reg | 5349 | 3612 | 3612 | 5349 | 5349 | 1737 hardware: PSR bits 8-27 read 0, SPSR bit 4 reads 1 |
| arm7tdmi/arm_mul_mla | 5327 | 4764 | 4764 | 5144 | 5144 | 183 hardware: a multiply does not write r15; 380 unpredictable: r15 as a multiply operand |
| arm7tdmi/arm_mull_mlal | 5311 | 4748 | 4748 | 4996 | 4996 | 315 hardware: a multiply does not write r15; 248 unpredictable: r15 as a multiply operand |
| arm7tdmi/arm_stc_ldc | 5039 | 5039 | 5039 | 5039 | 5039 |  |
| arm7tdmi/arm_swi | 5037 | 5037 | 5037 | 5037 | 5037 |  |
| arm7tdmi/arm_swp | 5016 | 4822 | 4823 | 4822 | 4822 | 194 unpredictable: r15 in SWP |
| arm7tdmi/thumb_add_cmp_mov_hi | 5322 | 5220 | 5220 | 5322 | 5322 | 102 hardware: Thumb CMP r15 restores CPSR from SPSR |
| arm7tdmi/thumb_add_sp_or_pc | 5349 | 5349 | 5349 | 5349 | 5349 |  |
| arm7tdmi/thumb_add_sub | 5349 | 5349 | 5349 | 5349 | 5349 |  |
| arm7tdmi/thumb_add_sub_sp | 5349 | 5349 | 5349 | 5349 | 5349 |  |
| arm7tdmi/thumb_b | 4766 | 4766 | 4766 | 4766 | 4766 |  |
| arm7tdmi/thumb_bcc | 5041 | 5041 | 5041 | 5041 | 5041 |  |
| arm7tdmi/thumb_bl_blx_prefix | 5349 | 5349 | 5349 | 5349 | 5349 |  |
| arm7tdmi/thumb_bl_suffix | 4766 | 4766 | 4766 | 4766 | 4766 |  |
| arm7tdmi/thumb_bx | 4766 | 4766 | 4766 | 4766 | 4766 |  |
| arm7tdmi/thumb_data_proc | 5349 | 5349 | 5349 | 5349 | 5349 |  |
| arm7tdmi/thumb_ldm_stm | 4296 | 4296 | 4296 | 4296 | 4296 |  |
| arm7tdmi/thumb_ldr_pc_rel | 5041 | 5041 | 5041 | 5041 | 5041 |  |
| arm7tdmi/thumb_ldr_str_imm_offset | 5041 | 5041 | 5041 | 5041 | 5041 |  |
| arm7tdmi/thumb_ldr_str_reg_offset | 5041 | 5041 | 5041 | 5041 | 5041 |  |
| arm7tdmi/thumb_ldr_str_sp_rel | 5041 | 5041 | 5041 | 5041 | 5041 |  |
| arm7tdmi/thumb_ldrb_strb_imm_offset | 5041 | 5041 | 5041 | 5041 | 5041 |  |
| arm7tdmi/thumb_ldrh_strh_imm_offset | 5041 | 5041 | 5041 | 5041 | 5041 |  |
| arm7tdmi/thumb_ldrh_strh_reg_offset | 5041 | 5041 | 5041 | 5041 | 5041 |  |
| arm7tdmi/thumb_ldrsb_strb_reg_offset | 5041 | 5041 | 5041 | 5041 | 5041 |  |
| arm7tdmi/thumb_ldrsh_ldrsb_reg_offset | 5041 | 5041 | 5041 | 5041 | 5041 |  |
| arm7tdmi/thumb_lsl_lsr_asr | 5349 | 5349 | 5349 | 5349 | 5349 |  |
| arm7tdmi/thumb_mov_cmp_add_sub | 5349 | 5349 | 5349 | 5349 | 5349 |  |
| arm7tdmi/thumb_push_pop | 4098 | 4098 | 4098 | 4098 | 4098 |  |
| arm7tdmi/thumb_swi | 4766 | 4766 | 4766 | 4766 | 4766 |  |
| arm7tdmi/thumb_undefined_bcc | 4766 | 0 | 0 | 0 | 0 | 4766 documented: Thumb Bcc with cond 1110 is undefined |
