type Input* = enum
  UP, DOWN, LEFT, RIGHT, A, B, SELECT, START, L, R

type DsInput* = enum
  ## The DS's two buttons a GB/GBA has no bit for. The desktop binds them
  ## apart from `Input`, and only a DS game reads them.
  dsX = "x", dsY = "y"
