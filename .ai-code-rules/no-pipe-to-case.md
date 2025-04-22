# Rule: Avoid Piping into case/cond/receive

## Description
Avoid using the pipe operator (`|>`) directly into a `case`, `cond`, or `receive` statement. This style hinders readability.

## Example (Anti-pattern)
```elixir
data
    |> case do
    ... -> ...
end
```

## Prefer instead
```elixir
result = data
case result do
    ... -> ...
end
```