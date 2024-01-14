# zig-present

`zig-present` is a command-line tool for creative interactive TUI presentations.

Presentations are expressed in a simple text format. Here's an example presentation:

```txt
!zig-present
# Coffee Brewing
How to brew coffee with a french press

/next_slide
# What you'll need:

- French press
- Ground coffee beans
- Boiling water

/next_slide
# Steps

1. Add ground coffee beans to the french press
2. Add 1 cup of boiling water to the french press, per 7g of coffee beans
3. Cover the french press with the lid
4. Wait 8 minutes
5. Push the plunger down slowly
6. Pour and enjoy
```

Every zig-present file must start with the line `!zig-present`.

Any lines that start with `/` are commands. Every other line is interpreted as formatted text for display purposes. A few commands are:

```txt
/next_slide
/docker <args>
/stdout <command> <args>
/pause
```


