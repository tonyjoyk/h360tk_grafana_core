Feature: Basic Calculator Functions

  Scenario: Add two numbers
    Given I have a calculator
    When I enter "5" and "7"
    Then the result should be "12"
