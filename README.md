# AI Code Review & Test Generation CI

This project implements GitHub Actions workflows to automate aspects of code review and testing using AI.

## Features

1. AI Code Review
   Custom Rule Enforcement: Define project-specific coding conventions and anti-patterns in markdown files within an .ai-code-rules/ directory in your repository. These rules can capture nuances beyond static analysis capabilities (inspired by conventions like Elixir's anti-patterns).
   An AI-generated suggestion on how to modify the code to comply with the rule, allowing developers to potentially accept the suggestion directly.
   ![AI code review](code_review.png)
2. AI Test Writer
   Test Coverage Monitoring: A GitHub Action monitors test coverage for newly added lines of code in pull requests.
   Automated Test Generation/Suggestion: If new lines lack test coverage, the action adds comment with Suggestions.
   ![AI test suggestion](test_suggestion.png)
