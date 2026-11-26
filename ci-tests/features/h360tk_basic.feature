Feature: H360TK Behave integration working

  Scenario: Test the creation of orgUnits
    Given A top level Org Unit exists for the current run
    And An org unit exists in the current org unit with name "A"
    And An org unit exists in the current org unit with name "B"
    And An org unit exists in the current org unit with name "C"
    ## TODO: add some assert


  Scenario: Test the creation of orgUnits
    Given A top level Org Unit exists for the current run
    And An org unit exists in the current org unit with name "A"
    And An org unit exists in the current org unit with name "B"
    And An org unit exists in the current org unit with name "D"
    ## TODO: add some assert



  Scenario: Check we have patients
    Given A top level Org Unit exists for the current run
    And An org unit exists in the current org unit with name "A"
    And An org unit exists in the current org unit with name "B"
    And An org unit exists in the current org unit with name "D"
    And That Facility has a patient with the following details
        | patient_name     | gender | birth_date | phone_number | patient_status   |
        | John Doe | M      | 1990-05-12    | +1234567890   | ALIVE   |

