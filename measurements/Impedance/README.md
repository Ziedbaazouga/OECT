# Impedance (EIS) Measurements

Place your Electrochemical Impedance Spectroscopy (EIS) files in this folder.

`OECT.ImpedanceDataLoader` expects a single workbook (`.xlsx` or `.xls`) with
three sheets:

| Sheet                                   | Column A                | Column B (optional) |
| ---------------------------------------- | ------------------------ | -------------------- |
| Frequency (any name containing "Frequency", "freq" or "Hz", or the 1st sheet) | Frequency (Hz) | — |
| Name containing "Magnitude" or "Mag" (e.g. `Magnitude_Data`) | \|Z\| average (Ohm) | Std Dev |
| Name containing "Phase" or "Phi" (e.g. `Phase_Data`) | Phase average (deg) | Std Dev |

To load a file, select **Impedance (EIS Fitting)** from the Model dropdown in
the GUI, then use **Browse** next to the **File:** field to pick a workbook
from this folder and click **Load Data**.
