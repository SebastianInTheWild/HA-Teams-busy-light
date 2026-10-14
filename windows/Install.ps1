Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
. ($PSScriptRoot + "\Messages.ps1")
$DetectedUiLanguage = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
$UiLanguage = $DetectedUiLanguage
$Messages = Get-TeamsMessages -Language $UiLanguage -Root $PSScriptRoot

$CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$CurrentPrincipal = New-Object Security.Principal.WindowsPrincipal($CurrentIdentity)
$IsAdmin = $CurrentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw $Messages.SaveAndRun
    }

    Write-Host $Messages.Elevating
    $ElevatedArgs = @(
        '-NoProfile'
        '-STA'
        '-ExecutionPolicy', 'Bypass'
        '-File', $PSCommandPath
    )

    Start-Process -FilePath 'powershell.exe' -ArgumentList $ElevatedArgs -Verb RunAs
    exit
}

if ($Host.Runspace.ApartmentState -ne 'STA') {
    $PowerShellPath = (Get-Process -Id $PID).Path
    $InstallerArgs = @(
        '-NoProfile'
        '-STA'
        '-ExecutionPolicy', 'Bypass'
        '-File', $PSCommandPath
    )
    Start-Process -FilePath $PowerShellPath -ArgumentList $InstallerArgs -Wait
    exit $LASTEXITCODE
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

function Get-InteractiveUsername {
    # Prefer the user who owns the interactive desktop over the elevated account.
    $ExplorerUsers = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue |
        ForEach-Object {
            $Owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue
            if ($Owner -and $Owner.User) {
                $Owner.User
            }
        } |
        Select-Object -Unique

    if ($ExplorerUsers) {
        return $ExplorerUsers | Select-Object -First 1
    }

    $LoggedOnUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if ($LoggedOnUser -and $LoggedOnUser -match '\\') {
        return $LoggedOnUser.Split('\\')[-1]
    }

    if (-not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
        return $env:USERNAME
    }

    return ""
}

function Show-InstallerDialog {
    param(
        [string]$DetectedUsername,
        [array]$ConfiguredUsers,
        [hashtable]$Messages
    )

    $Form = New-Object System.Windows.Forms.Form
    $Form.Text = $Messages.Title
    $Form.StartPosition = "CenterScreen"
    $Form.FormBorderStyle = "FixedDialog"
    $Form.MaximizeBox = $false
    $Form.MinimizeBox = $false
    $Form.ClientSize = New-Object System.Drawing.Size(900, 720)
    $Form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
    $Form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $Form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

    $Header = New-Object System.Windows.Forms.Panel
    $Header.Location = New-Object System.Drawing.Point(0, 0)
    $Header.Size = New-Object System.Drawing.Size(900, 112)
    $Header.BackColor = [System.Drawing.Color]::FromArgb(25, 45, 70)
    $Form.Controls.Add($Header)

    $BrandMark = New-Object System.Windows.Forms.PictureBox
    $BrandMark.Location = New-Object System.Drawing.Point(28, 30)
    $BrandMark.Size = New-Object System.Drawing.Size(48, 48)
    $BrandMark.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $BrandMark.BackColor = [System.Drawing.Color]::FromArgb(25, 45, 70)
    $IconBase64 = "iVBORw0KGgoAAAANSUhEUgAAAQAAAAEACAYAAABccqhmAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAE8NSURBVHhe7Z0HeB3F2YVvQn7SCCQQSuiE3pIQkgDuVu+9uxfcwL3IllXcTTMEEgiETgLB2MbgLsu9V4wBY9OLjWXLlty7NN//nNkdae/sXt29/Uqa8zwnMraku7vZ98w3ZWcdDiUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJXvqMXLnBWMm77u7eMKB5DETKx8eM75yYtHE/U+NGb/vJVj7c+VE/FvR+H0pYybX3I2fkX+PkpJSE1DbtmXnFU06eF/xpIPFxZOqFxVPPLC7eNJBmvDYaZo0rZYmP8lo8rQ6/mf+39Pq+N/hz/gefG/xxOrd/GcnHSwePb76/rZtl50nf46SklIYaVRx5R0lkw9NLJlcs6Ns6lEO9cTHz1LZ1GNUPLmGxk48SGMnHnDjg/x78TP4WfwO/K6xk6o/LZ5yaNKoCZV3yJ+rpKQUQhWWVbYvmVIzs3hyzVkAO+7Rk1Q8qdoCbu+M3zX+0RM0+UlCOJwtnlwza+zEA+3l41BSUgqiCot3/6FkUs3McY8cp0nT6qhk8iETvP42PgOfhc8snVwza0TZnj/Kx6WkpBRAxQ6cf37RhAMTSqcePYn+uz9be7vGZ+KzS6ccOTV24oGJXbu++lP5OJWUlPysEWXf/LFkyqFNU54iKp1ymMZOrDLBGTxX8WPAsZRMPry5sPibP8nHq6Sk5CcVlu3tUjrl6LFJT5yzgDG0nvjEOSqdevR4YdmebvJxKykp+ajR4yrH8RH9R46HuNV35Soqe+QYTXziLI0Zv3+8fPxKSkpeasy4vc9MeRJlNgb5whF+4Sp+jDjWovH7/iGfh5KSkocqBPxPUUgG+rw1jhXHPLpsrwoBJSVvVViyuwytaVOCX5iHwJNEo0p/GCefl5KSkhuNHPtVAfr8wZjbD5Rx7BgcHD72687y+SkpKbnQoOGf3lky5fDx8B3ws2sMDB6nkqlHjg8dtf0u+TyVlJQkxcY+ff6Y8fu2THqilsZOaMrw655QRZi2LBq/fyvOTT5fJSUlg0YVf1uKATQTSE3cU58iGlH8nRoPUFJypX6DN91SPPnQydIpR0wANXXjnEomHzrVf/DW2+TzVlJSwqh/6Z538DRf0+73u3IVf5pwdNmeGfJ5Kym1eA0cuuU+PHdfwp/bl+FpHsa54RwfGrH1fvn8lZRatApLd789eRpafzM4zck4R1Q68vkrKbVY9X6o4uaxEw+e0p7uM0PTnFwy5RB2Fzrds9/SW+TrEEqlp0//cVL26mtSc9c+kJK3Pjk1d23nlJy13ZNzV6en5q5un5a78ebMzHU/k39OSclnjSj+uhT9YxmW5mqsEBxR/E3IZwRS8tb8Li1vY9f0gi1vpBds3pGWv/F4RqdtlNX1E8ru9qnmrjsos/N2SivYdDq9YPPXaQWb38/I3zIoI3/LrfLvU1LyXLfd9n+jx+3dPv6x0yZQmqsnPHaKRo/7Yfs9jnt+Il+OYCg5Z12r1PzNb6R32lqd020n5XTfRZldPqKMTlspvWAzpeVv0r1R+1qwidILtlBm5w8pu9tOyu3+GaUVbD6X0WlreWr+pgz59ysp2VbXvkv+Wjypuq54UvMd/JONcy2eXFPXq+/Kv8rXI5CKz1pxV3rBlhmZnbdRTvfPKKPTBzrknhuBoFUJO/F71ifnrkqUP09Jya2GFn4+Spv6M4PSnI1zHlr02Wj5egRKqbkbxqR33nYCrbfWypuh9s6beDcB3Ya0/C2vt0t68xL5s5WUXGpU2e73+bJfC0ias3HOo8r2zJWvh78VkfTWZemdtszP7fGF3uJvsIDYdyNU8BnpnbZ+lpRVoaY5ldzrrmsTfz16XOU32GFXBqS5Gw8JjRlf+e1dd+X/Wr4u/lJsysJb0jtt/RRgysAGxht4tyCj07bjiVkr0uTjUVJyUl7eW3cXTdh/pik/8uutcc5jJuw/m13w34BsK56YOPem9IKt32GAL1CtvrU3UGaX7ZTR+cPahMwV6fJxKSlBP8L/9HxoRfK4R07wV3HJgDR345xx7r0HLEsxXhN/KDL13YvTCjZ9Gnz4hTfwqcOMTttOxWVXtJaPT0npx/if/kM39cemH/Ze2dX8jM1CHh7+QX/jNfGHUnLXLtDK/lDAL7yBDwymF2zeE5Xy1u/kY1Rq2eI3+6ARH5XiLTsyGC3FOPdBIz4WC4L88vLRxKxlI4PX53fnDZTb43NKzl0T8MFOpaYjlLp8AczgUTseb0krAGXj3AeP+niafl1wTXzqBnSMnX5LWsGWE1jNZ4YxVN7EFxolZi0rkI9XqWUKN/n/4Q+4+Vt6AAwa+dGT+nXBNfEpAFJyVr2NFje0pb/ZWV0/ptS89d/c1r70l/IxK7U8ofznW2Ph5lcBUB8AuCZejwPEJs25J73T1lqs0JMBDAcjmBKylj4sH7dSyxNucv4izYHDPpzWfDcAcW8EwMARHz6lXxdcE68DIDln1Uu53dH6m+ELB2NAMCV33afXXjtQ7YvYgoUSF4NdeKz0R30HbxjP3/OHzT/9ZQvQwtUYBOw/ZNME/brgmuDaeNwNuP/+xy9NzVt/EGv8ZfDCx5soq8vHFJU6N0Y+fqWWI2MAnNejX8XACXgKUIbY37aALxyMacCe/ZcNMl4TbwIgNm1hHlbgmaELL+d0/5ySs1f8Sz5+pZYjYwCcn5n3WjbfBGRCFRVN2O8Xm+CXbQFiSDypmrAEOrfgvzl6///n3s4EJGWtfAlP98nAhZtRAaTkrN1x9dVX8y6gUsuTmALEzf7L+1oPaF1Yuuc0VsUVja904X32bREILkNBBjLI1pYC7zvduv0wrJT7hQ8B8H8puWu2YaRdBi7cnN5pK6XmbzjdOuLp2+WTUGoZMgbAheeff8HvR4z96ktUAWPG7fXM442urHdjoWAKgRAGwbhHT9DIku+/xjVwOBwXeRsAt/xx8HWpeesO+fJsf/CsjQPEJM1Mlc9DqeVIdAFw0/9m4PAP541/9CR2yPHAe+ttCgYeDsZAMIRCY2FgAWkgPWlaLQ0p/HSBw+G42OFw4IlATwOAf1/bji88kJa/sS5cp/9kYweiuJR5Q4znoNQyhZv9x516zhxRNvUIFZZ9T4Vl3+nGn6092sm7NY+D99CYcXuoaPxeKpoA+M2BIAdBKENg8rQ66t6vHMuAf+VLALSLeyOJ79lXv4VXeBsbksRnLJyqn4PX055ho+69N7Tp3HvdxIJea98r6LWuIr/Hmor8Hqsbd3cLW/xbXveV9txVc44dd1lZkW3yCs/cWXOWpy5YUZFRsHxJev7SZel5S5ZrLt/eufdG6txrPXXqafQ6JxfYMH6ue98t1H/oDhpZ8i0VTbCuDBoNAgtY/W30/4smHqh9oO3wBL0C8KYLwOFpH/daJsrqphMAn1Nc+qIn9HPwatYjLJTfY1W7rg9uWtmtzxbqOWAHde+/nbr3+1D3Ntfuu426NeY+26gr9wfUxY27Pqi5i+7Ojbm35k4mbzW7V4MLZPfUnK9/1byF8htzD815Fs7ptoHS85ZRmpOXOjkVzrXnlOwl3FmdV1GfQdt51TAG3YYyrfsggiCUITDh8TM0vOjL7Q6H4waHw3G5HgDoFtkNADGb4mgf/VJWVpePmlQAxKbNF6sf7Z5veCm/56pRXftsoR79P6JOvdZSQc81ule7dg/N+a7cXXNe91X23E1zrjt3XUU5ll5p7S6as63ceSVl6caftf9e0bg7raDMxlywgjLqvdzkdDjfhvM0p+lOyVlKydkV1Ln3ehpR/DXvIsghMCZEIYBtwbv3XfSow+H4rR4AF3q4DkAMpjraRPwrExtwNKUAiEmdKyoAPP/QtLoBeT1WjOz10KeEstUT8F3Cr4NvG3674LuE3wL6kINvht82+Dr8AnzNDdUEQiC/x1oaWfwVFZbtpsIyLQhQFThVA0EKAbwkdMz4fcfvuCO5o8PhuNLhcFyqjwNgbtzuI8GABvCc97dWU6IBv383+gycMQgYlTS9SD8Pn55/CLrye6xujZbfFvzuwPe01dfBtwW/CfpG4NfBt4TfAL6A3wS6bBl02QUy/L61+s7gO8PPnbuMkrIqqHu/TVRY+g2NKsVg4h4qtOoSBDwEqnjr33/IplkOh+Mqh8NxjcPhwC66F3gIg3ig6mfX3Jh+T0ru2mNNZhqw6yfUNuLf3fSw8yT0Qi1yFPRYtQFlvwl22f4E3wC/CXTZJuAbAd9Nq+8N+HbgDxr4OvypucsoJWcZpeYto4dHfEyjSr+lUSUIAcwguAqBwAQAX/U4qfrsX+/vjQ0zAT8qAAwCYiGQ3XJY9P8BzwUOx0+vTspZuVMbCJSBCy9jqjI1f8O5O/84uL3e5fGk2xNaFfRa1wqtf6de7lt9E/AS+LbhDwH4gS/3fQDfEn7X4BudnL2Euj64jkYUf8FnCHgIlBpCQF9QJELA/1WA1vr3HbTuXYfDcb1hANCbKUARABg7+FV82sJZ2v5/ZujCyRisTM5e+c3551+IcxfjHp6cd+hU0HPVlB4DPjZDbwDfJfyBAt8l/BbQG8C3hD/g4JvhDwb4DQGwlB/z4MKPaUTxVw0hoFcCzrMDUlfABLPnxrr/ogn7jtx6ayKehsPqv2v1/r83A4BiMRV+9oK2kc+PwBt6ZODCzXheITZt7gx91gPB13QCIL/n6jnd+3/oEn4T9BL8JsitrPr5ZpvAt4A/txH4Uf7naAGAKcUBQ7fQ8LGf85mBUfUhIAYGA9UVOMif/c/v9s5jeut/k17+G/v/dvvCcgBccvXVUa1Tc9cez+gczuMA2huE7mvzWD/9uL2pfEKn/B6rlmIePyDgG+A3gS7bBHwj4BvgN4HvTT/fJvxBA99Nqw/w0f/XpgSxTmAJ9R20gYaO2UnDx36ph8B39QODoitgXCPgewBU8deADR71yUaHw/EHvA5VD4ErdAjQ//cUAmMAoBtxRWzq3Pnh/EQgyv+k7JV7fv7zq+5yOByXebn4KXTCKj0eADbBtw2/B+Bbw28BvRvwA1/u+wC+Jfzegy+cnKMFwIMPr6EhhTtoWNHnPARGFn/DQ0CMB/DpQb+NBVTR+MdOoUtRfdudyXh55i0Oh+Nmh8NxtWH6z5PyHzIOAuLn8Xsuu/vPw7phSXC4Tgdip+IOsa8/ox8vwk8sfvLk3EMnLM3FKj478Jsgt7Jd8HX4PQXfEv6Ag2+Gn4NvF34T+Bbwy7C7Ad/o1Jwl1GvASho06iMaOnoXDwE+HlD8rXUVIE8LmgBvzFVUNvUoXBedMGWgDv4deuuPffIx+o9NMu2O/htlmAXgi4kwo3BjbNr8dVoVEF6bgiKYUnLWVv/2t/fi0WeEHyoAT8c+QisEAJbqmqD3Enxb8Jugtwe/CXxvyv1wm9az0c9vDH50AVKyK6hX/2U0cOQ2PIlHQ8fsouFFX9BIvSvQUAW4mBEwQe7amPKb+MRZyun8Flb8oeW/W+/7A1YjAN6UwGIdAAIE4wiA6ppb7+pdkF6wtTaj01YThKE0Vv+17vAPXAesfcDgJ0IL4dV01gFYBoAn4BvgN4Eu2wS89+DLrb4JdCvLoMv2I/hm+H0v952crcEvAqBHvyX08PAt6JPTkNE7adiYz2nEWH1WwGUV4Ek3oIpKJh/m/f4uveY873A4sPmF6Ptj+kvM/QNeTxb/GCVWAmL84Dd6RXEjfn+HmDdez+3xpQnC0HgDfydAfHr5h3oA4hgRAr5UP6GRUwCofr4l/LbB1+EPFvgNrqDufRbTQ8M206CR22mwUxUgxgL0ABjnTTdAK/vxurMuvedi7zvc9Hj5J0p/3Pyi7+9L6w/hZ/CzYl8FDAReh0rjJz/51V/iM8p3hL4rsIEP/KXlbTp2w00ZGfrUJ4z+P0LLm8HP0AmDgDwAvADfLvxm8F3Ab7Ofb7vVl0GXbQd8u/CbwLeAX4bdEnwX8POWXga/IQC6PriQBgzdQANHbKNBoz6moagCMBYw1tduQBVNeOwUlU49Upvb5c1HHA7HnQ6H40/6V/T/UfqKhT++tn7yQCBKaoQLPueWq66LT8UuwZh2C1UIYGkyHlK6577SUXr43apfA1+7P6ERKgA8pmuC3JUDAb6bVt8b8D2D37dy3y34tuG3AN9lq685ibuCuvSaT/0Gr8NLOfFSDl4FDBvzGY3AjICpG2AvALCnIVb5jZmwvyo2cSp2+QX09zgcDkx5of8vSn+AKkb+fb35RTcAYSK6AfgcVBu33HpXzx5p+RuPBz8ENuCtwIRdiu9v/9Tj+vnjeqD1t1r74Ms1CJ6w8QaewTeBLjsE4Ae+3PcNfDP8wQO/Hv4suII695xHfQetpoeGbcFLOWhw4Q4+IzB8rOgGWI8DWAdAFX/FN/b3H1z46epbbo/HXneA/s96+Y9WDze+KP3F3Lcvrb+Q6Abw/RX1lhUtLAYa8dm33XZ3396peRuqg7dMWCv70fLf3+EpLHpCGInrgC6KqIDEsw9NA37IbQDYBd8l/BbQhxx8M/y2wdfhDzn49fDjqcDF1KnnHOozcBUNGLqZHh6udQOGIACKvqhfGMS7AaZxAONAYBV/rBetftGE/Qfzu85Ayf9Xvb8P+BECGPS7UR/1N5b+/mz58HvEbAAG1tDCogrAZ+NYbr/u9+m5SdnLP8M8fGD3DcRLQDHusOnwvfeVFerw82PQQxCDf6ICEqP//rgGwZHLAGhG/Xx/tvpuy30ZdkvwXcDfaD9fbvWNLqeCHu/Tgw+voP5DNtZ3A/hsAB8H+IovDzaOA8gDgWVTjvJlvcWTqk/0Hbhu+vXXt0vWgb9X7/Pjz7jp0RKjRRaDXsZpL3/d+FZVAAIHn41jwPHcff7PL+8YlTRzFlpm7QUi/t08JLPLRxz+hIyKTdffmIr3HAB+dIFQ+ovrILf+vlZAwZVlAAQCfDetvjfg24E/aODbht8CfLutvgn8JQ0B0H029X5oOfUbvEHrBtTPBmAcoGE6cHQZNhnVBgKLJ1UT3mA0+Yla3uL3GbT27T/ck5+rt3C40QE//myEHyUv4EfLLOAHrP6+8eUqAJ+JzxYLjxACOMY/3v3nYYOSspZ9hBCAfaoICvBs/8d8jj81d93eBzr+A1XQ/fqUp4Afpf/1Ut/f3yEYHDkFQAjAD3y57wP4lvCHC/jCSykpEwHwLvV+aBn1G7zeeRxADwCMAWCrsJIphzn0fCnvuH2nho7+bFNel7ceu+b6VmjxBfh/0QHDTY8bXpT9aPHEaj8x6BeoVs84JShmBERXQAzA4XgRUuiPt/5r60nFiRkVm9PzN/NderO77aCMztsaXUacXrCJj+wDerT2qCaSsld82Sby+Wcu/PXNsVIVJOAXpb9x/CMQIRh48QB48AN74LuE3wJ6A/iW8AccfDP8TQ58E/xG8DUnZi6lxMxy6tJ7Pg0YupEvBMIioJEl3+iDfnvxph4+BjC86Kujgwt37Oo7eN2czPxXJ9/5hyy09qJ1w00O8Hmrqt/4aGnFDY8SXLT8MvyBavXEjAAAA2gADuDheHBcABLHjvEJHDv+fP9NtxT0bBf98r8T0su3puSuOYQVhJg1wLZdGDjk7raLVwuZnT+klLy1JxKzlu2KSJw+/e4/Dx3scDg66KGCayKqIGMQilWPovT35/hHcIVttxEAJtBlm6C3B39j4HtS7ptgl8D3W6tvAt8Cfh+X79qC3w34SZmAH39eQfEZi47f33boxMj4CVMS059+LiXz2edTs154Pj335eeSM/75WFTcpKL7Ww/oc+WVf0nHOzd0yAU4GOTDTS7AF60+Sn6U22hxMdqPvq4o+4MBPyTWBQAwgAbgAB6OByGASkCMyItqQIQYzuOBX198e8otd/bqd+8D48se6PDUM60jnn0efqDDP579a+spk+7840ODL7+ydbZ+XdDK4/fgd4hWH79bwC+CENcC4x/+HvwMvrCnPrbXNgHvb/Dd9PM5yPiqux56I9ydGuz09/krKJ1bgzgDNkCfBpug1v/eCH3uckp1sg61DL1hME+G37/gW8Cvgy+cnL2SEjIWH3Y4ftnOMEItW/SXcVMDeHGD4+/ETY8b3djqi/6+2OAT8AUTfiFjCAA4YwiI7gDCCscO6MW54hyNIItwg8WfxbURFQSMP4vuD66JXAUJ+MW1aJqlv5DLAAjS8t3sLisoOWcZJWQuaXCG5vj0JRSPr7Lx9+lLKC5NN/6cXuHk2DTdqe4dk2Llxc5OXkzRFsb3Njqy7y/wLeAXARCfUX7k4sv/jN14cdOKG9kIAIwbWwBvBMIKfNHqo+RH3xvlN1pgDHQFE34hfB5Aw+eLEBDdAYQUjhnHjnMQQWAMPpy7uA7C4toYr4vxmohW31gFIXiMMx9NG37IMgBM0LsH3xL+RsAXxvPs//nfV7RpywHasKnB6227ytob7XmdD8bnly/5gTI7LecwegW+CX574DsFQHr54d9e/hdRAQjAjRaVgLi5BfTiJjeCLzb1BGC42dHfRx9clLqhuuFFCIjuAEIJ4YRBSRwzWmjAivPBeeH8cJ4iDIzVkKvrYrwmqCxutKiCEEBG+IMZhP6XUwCYoLcHvwl8N+V+fdnfGf3XJfTh9hpqqjp5spZXMahYPIbfB/DhhIwKbQwAAXDFfXgmHSALwI2gCyMgUC6LGxzAAJzrdYgAE1o59PUx/y5udr5Xfxjc7MbuAEIJ4YRjRVkOSAErzkdUBDhXnLMIBBEKxuuCfxPXBT8jrgl+lxj7wFSfsQpqHvBDPAB6f2ABvXfgy62+DL0cAAAHLX5T1YGDp50DwAL2xsG3gN8Cdhl8YREAl1/V5m+G1XJG46aGBfBo1YzQo4xGqY8Wzgi+aPXD7WYXIYBQQh8c5TjgBKQiCHBeOD8RBjh3cR1g+brge3BdcP0w1SmuCSoMMfYRDlWQ/4WXauJdev4G3x38PAAKtAoApXRTVX0ApKMcNwPvEfgewm8IgEO/uy4apSxuftz4uJGF8d9ozXBjAwy0avg+3OBo7QEObnIBPqAKR/CNwjGJKUJRDQBSnAfOR2zPBZBxvjh3XANcC6ON1wXfKyogcU1QYRhb/XCogvwrvEXXOQBcg28JvwF8O60+tz7Cj9H8ZhEA6Mo0EgBm+H0HXw6Aa2/OQGuGFhw3sdEAAS0jbmyAgZsb3yegBzi4ycXoflO60Y3VACAVQSB258W5ohXHufNNRiWL64LvwfdizAPVhGjxjd2f5tPqG9UQABbgu2n1vQHfOKffXAIA52YVAIEEXzgxcznFpZdXO35xC6CGROsoWu+mAHKwJK6Hui5C2V1WVODV2Z6A7025b7WYp7kGgBl8C/ixiMcCeE/gj09fTAkZyygubdHRpIwXczr1nBGd1216QqeesxK69XwvoduDCxN69l+c0LP/soS+g9bE9x20Pr7f4E1xA0d8GDt41Mcx8JDRn0cPG/NVFDyi7LtIo0eO3xMRDh6DryXfRnTrszGiQ9yMiL+2eTUiKml2RGzKvEjujHmRMenzo+LT50fFpS2Ijk2dGwPHJM+LjU6bExeVOjs+MmVWQmzKrAR8NRr/hu+BY9LnxcZmLIyJyyyPjs9aEgUn5iyPhJNyV0V44tTcjRGpuWvaxKUtR9cifGUKAJvlvi/g1wcAxgDSm08A+GNazy74DcZ/L6ROPd6nvgNX0UNDtW3BsCPQ8KIvaWTpd3xJ8JgJlVQ88SCVTKqh0smHqWzqERo39Rh/s8/4R05ofvRk2HrcoyepZPJRGlG8n3r0/4SSspdTfAa2RV9FKblrKTVvHaXmrae0go2U3mkLZXB/QJmdt/Hlvpq3U1YX4Y8C664f889Mz998JL3gg4rUgo35MnthofoAsAm+J+W+DLyT9RV8WMTTHAIA5xFc8J0DILfLDOrZbzH1eXg19R+6kQaO+EDbE0DsDVjyNRUangYsmlBJY/Eo8MQqKsbuP/oOQOHtaiqdcojGPXKERhTvocxOKyk6eQ4lZJRr1xB7I2Qvp+SclZSSu4ZbC4YN9XZ+GAiPDwfO2oNGW/kzB3jQKL1gy7LEjMWYcQgf8QDopQWACXxv+vl24S/Qlu9itd627dUyV01GWAeA6UysSHQJvwXsnoDvGn5jALxDPfuVU5+HV1H/IRvo4eFbG/YEwA7BxXgi0LA3oNtdgcLbpVNqeCjkdl9DUcnv43kISsisoER+/ZfzBVIpuau5RXUgrG0lJodBoL2JP2Kc3umDvQnZ5ZixCQ+JAJDB93e5bwTf+MAO5s7LJn9Iz724i/75gk0/v4v+4eSdNO2ZHfTl10dlPl2qpuYM/7m/P/spPfMvCz/3KT3t1jvp0Sc/4c8BYB2AFfi+wm8GXrY5ALQ9AZp3AMAlk6v51/T8pbwSECHAd0nKXkEpvHuAEEAXIdQBAG/gTyGm5W/6KjL1XTFoG1ohAAqMARBw8KWn9TqhL7eEopIXu3eS5kjJEYnl9EDH+bRq7T6Zc5f67vtjFJlUTu1iFlLHhEWa4zV3aMTt4TjdsdrfJcrg+6HVN4PuwmkVFJ/WMgMALpt6iIaM/oZiUt6juLT5eC5C+/8jezne2acHALoCDSHQEAChCYG8Hl9ScvYqbK8eehkDwONyXwZddpAe00ULjAd2sD7frnbvOc5/FjAGe/luYzYB3pjTFlNcWgXFpS2g3C7TqYfoArSgAIARAljKHpU0m1dDCRmLta5A9or6roAxAEJbBWhbi6fmbzwdEzMdqw9Dq+zOKyoKem71DHyb8PsLfDP85ufz8bSe1wFgAXvj4FvAbwG7J+B7BD8HHy7XvyIA3mnBAXCY+g/dSZEJMykubR7vCuCaJ2Xj9ekr9ZkCMSAY+gCAMR6QlLVsqMxj0JXVeUVFfs+tASr3fQBfh79R8HX48Rw+Hs31OAD0vrsMvEfg+wF+E+CuXA++gF8FAFwyuYZGjP2eYpLfpZiU9ykufUF9FdAQAM5VQKgDALsTJeesfkfmMehCAGgVgAXsXoNvhj+Qb9nBs/ieBsD3e47XD97J4FvDH0LwneAX4OtOXUxxqS07ADA9WFi2l+LSZlNU0rtSFYBpwVWUXB8A+nqBEAcAtihLyV6zWuYx6NIqgC1m4A3gewa/D62+CXpr8OXtuPwZAE0GfA6/FgCxegDUTwO20ACITZlJkYkzKDZ1DsVhLECfEcC6AISAdQCEJgS0AFgtAiB0y5IbDQAZdNl+BN8Mv4ty38oIgKTFtG6D9wFgBt8C/qBM69kFv5xi6z2fDwK22ACYrAVAdPI7FJkwXesGpM1v6AboAeA8DhA2ASAeNApNCFgGgAy6bDvlvgy5K/sCvg5/SvYyikoq9zoA3IIfzFY/rRH4dfAb4F+kAkBfD8ADIOlt6hj/P4pJnq13A7QVgsmYDQjDAEjOXrXG8Oh1GASADLpsN9N6geznm2zYmBMtuDcBgJ/la/jDAXwdfkvwTa0+wBdWASACICrxLeoY9yZFJ83i3QB5HEBeFRjyAMhaudaw/0JoHjfmAdBjiy34XYHvUatvgt4CfNvwa/P3vgeAhS1gDy/wdaeUU2yKCgAEQGTif6lD3H8oKmkGxabMoXjMBmAcQAwE5oTPTIAhAMS2a6HZgyGrYEVFXo8tZuD9Db4l/L6BXx8AOb4EAAaKnMEPGvyW03qNlftG8IVVAGgB8ANFJvyHOsS+QVFJ7/BxgPoA4AOBxgCQBwLNgAbaCICkrBXrDJuPhKYbkOEqAMKtn28BvrECiEz0JgCWOgeABeyBAt9lq+8OfCf4F1FMSjnFqADgARAR/wa1j32dIhMRANrSYG0gUMwEhGUAYPeiMAoAN/18j+A3gW8Bv8W0nhH8RuHX36aL/rtPAWABe0DA1+G3BN9WuW8E3+h5KgB4ALxO7WMQAJgJwEBgkwgAsdtwoN6x2LicAiCY4PvY6huX73oVALuP89+BtfQy8HbB9wh+P4HvDP9CFQBOAfAatY95jSIT36ZofSbAeSpQPBkYLgGwfL0eABgHCGEAdN/iH/At4Q8c+L4GAH7WVQDIoMs2Ae7KfunnW4GvO3kRxSTPo9zOKgC0AHhVDwBtRSDfLCS8A0C8bCQ0AZCev6Iitz4ALMC3C78JfAv4Zdh9BL8+ALKX8keC1/ohAGTQZZsAb8yuwPew1Xcu943wqwCATQGQoALAttLzl1fkdt9sDb8MuZVN0FuD7xJ+d/18N/DD+D84IsG3AJBBl22CuzEHBXzN0cmLKFoFQH0AtFMB4JnkAPAEfDP8gS/35ZYf5X9ipvcBEJuGnXXNwHsFv23wLeC3U+4b4I92sgoAHgBxr/IAiBABkGoIAP5UoAoAk0QA2AZfhz8cwBfWAmARrd2wX+bcpRAAmPqLTXUdACbAXdmXaT2fwF9I0UnwXBUAZT9QRxUAngsBkNNtsxlyK5vAt4Bfht0SfBfw69N6MvCNwQ+IUcL7MwBMgDdmV+CbWn3fyn0T+MkLKDppAUWpAHAOgOhXKCLhf/VdAG2LMBUALmUrAEzQW4DfGPx+6OdbgS+MPeB4AKz3LQBMcDdmP4HvstV36uebwRdGAESpAFAB4K0aDYAw6ue7gl9UANjM05cAMAHuyrbBt4DfDvguW/0FTvBH1VsFgAoAH+QyAJoA+Nx8BN/7AMBSWhPkVvaln++y3LcDvnOr3wC+0XNUAFgFQKoKALcyBYAJfAv4ZdgtwXcBv5f9fJOd5u69C4DEzAp7AeAKfFOrbxd863Lfc/DnU1QirAJABYCX4gHQdbM98G3DbwG+v1p9y1V7AQoAP4HvstW33c+XPd8A/wIVACoAvFd63vKKnC6bmwT4VvCLAMALOvwWAPXgW8Dvrty3A77LVt9VP9+q1dccqQJABYAvSstbXpFdHwAhAN8Ef+PlvpXxRF+HuIW+B0BY9/OdwdfgVwEAqwDwQVoAbLIE3yX8AZ7Wswt+w/SdHwLAFfgelvvu+vlm+G2U+5bgqwAQVgHgg9LylpoDQAbe362+jXJfht0KfL8EQDIgtwO+Bfx2yn1fwDeV+xZOmEdRCSoAVAB4KR4AXfUAkGEPNvhewO9LAOBn8TCNK/Bdtvp2wPdjuW+CXgdfWAWACgCvJSoAE/D+BN8Ev3/ANwZA+9gFtMbjAFhsDoDGwPew3PcVfEv4DeDDEfyrCgAVAF4qJWdpRVZniwAIs36+K6P/jhLe5wDwI/hm+G2U++7AdwG/CgAVAD7JMgD8Dr4F/BawewK+gN/nAEha5Hs/32Wr7820noVdgM8dP48i499XAaACwDs5BUAwwPcD/PK8vdcBkK4FgCX4Llt9O+B7Xu6boLcA3wn+eHiubhUAKgC8FA+ATpuCvnzXyjLosmXwfQmA73Yf5z+Lh2nsgW9d7vsKviX8bsFvgL+DCgAVAL4oJXtpRSYPAAvwvWr1gwe+7wFQ7hwAdsr9EPXz5Va/o8EqAFQAeK3k7CUVmZ02+gF8C/gbWb7rL/jrAyBmAa1Z52UA2AHfZasfmH6+udU3g88dN5ci4t5TAaACwDuZAsACdhP4JviD3+rXG4t4UhdTWx4A+2TOXao+ABIbAsAz8INV7ot+vhn8jnFzuFUAqADwWvUBEOb9fEvry3cxiNc2Zr7nAZCmBUC49/PN4DfA34F/VQGgAsBL8QAo2GiCvXHwLeC3gD3Q4IvFO74EQGR9AJjBN8Nvo5/vRblvp58vt/oC/vaxKgBUAPggBECGiwCwC37Q4HfxmC4PgGjPAwA/i4dprOD3tdU3QW8BvrnVtwe+gJ8HQIwKABUAPsgqAMKun+8Ev3ndPl6R7XkAHKO4tEUNAeAn8C3htwm+Cf5GwO8Qq1mrAGarAFAB4J3kAGgy4BuW7+KR3jbR87wLgIQFLuC3Ue67A98CflvlvtTPtwJf8/vUPvZ9FQAqALyXCAAz+BbwW8DuCfgewW8DfLF8F314jwPg+2MUl6oFgMfge1Hu2wLfotWvB98J/vfrjQDoEDebclQAqADwRonZSyrSEQCNge8H+E2Au7KLfr4RfPmhHW8DAD8b4RQAjYFvbvVN0FuA789y3wi+gL9dDP6sAkAFgJdKzFpSkZ4vAiCE4DvB767Vd166ywMgypcA8Ax8S/gDCr651eeOeZ/aRasAUAHgg7QA2NAkwRfLd/GKbO8CYCFFJMxvBH4b4FvAH8hy3wg/DwBeAbyrAkAFgHcyBYCbaT0ZdCubAHdl2+BbwG9cupu8iFpHzaPVngZAykKKiEefXgbfDL8JegvwXbX6voIvt/oNfo/axbynAkAFgPdyCgAL4D2B3wS4K/t5911s6tE6aq7HAYDpv46mAPAf+Cb4bZX7dsDX4IfbRuOrCgAVAF6KB0DeBhPsAQFfh98SfFOr7x58YQzgIQDWb6qSOXepvZUnpACwUe67Bd9Fq+/BtJ5d8NHyt4t+j9pGqQBQAeCDEjKWVKS5CAAZdNkmuBuzn8C3emgHAdAmai7NX7SbDlafpqoDpxr1gYOnaNv2g3oAzDPBbwLfAv5g9vON4BvhVwGgWQWAD3IVADLssk2Au7IX03p2wTcu341OWkgJGeWUkr2YkrPgcs2Z5ZQkO6ucEjIWeQW+udW3B751q+9ZuW8EXwVAg1UA+CA5AGTQZZsAd2U/9/NdgW9cwReRuICX9Nxx87g71Hu+bvwZcM5rHH6b4JvgDxL4xgBoFz1LBYAKAO8kAkAGXbYJ8MbsCnwPy31jP98K/MaW75pH9cO4n2+C3wB+I/DDbSJnqwAwBkCM6wBIyl5NiVlrKD5zDcWmraGY1LUUnbKGolLWOjk6dR3Fpq+jhMz1lJS9gVJy/R8S4RMA6RUVqbnrTcB7Bb+fwHfZ6tsA3xr+8Fq+67rVt+7nW7lt1GxuFQDWARCV9C5/ZVr7+PnUNnYRdYhfQrFpKymz83rq0X8LDS7cTkXjdtCkx3fRI09+TlOf/Fz7Ou1zKpm4k4YXfUJ9Bn1IeT02U3LOBopOWUsRSVo4JGatp9Q8M9SeuEkEgAlwVw5SP98Mvuetvgl6C/DNrb498K1bfTvg2yv3jeAbA6CtCgAeAB1iX6G/tfs33dvmdWodOZ3S8xbSkMIN9NyLu2jB4r20Y+cR2ld1mk6dqpUnhSx15mwd1dScpS++PE4r1xyk/7y9m8ZP3UXd+31ACVnreSDEpK3zqkII6wAwAd6YXYHvYasfaPAt4bcJvgl+W+C7KPf9BD6HP2o2tY54l9pGzWzRATBm/EF6eMRuatXxJerUYxY9/ewWWrP+B6quPiUz7RedPFlLO3Ydpf/N2EOFJTs40AiDuHSMLZhht7IhAC4KmwAwwd2Y/Q6+H8t9d+BbwO9zue8OfBP89vv5VuC3iXyXuyUHwIjiKhpaVEVTplXTu3MP07btlVRbWyfzGnB9v/skTZ+1hwaO+IiPHWAcwV1VkN3tU0rIXLzY4XD8KuQBkJK7zgy4K9sG3wJ+n8p9dw/tNN9+viv4XQVAv2YeAMOLq7j/+e9DtPmDU3TyJJOZDIkYI9r64WGa9NhnfNwgMsl1EOR030VxaQv+53A4fhHSAIhPL69IybERAC2kn2+C31a5bwd838t9I/gtMQBGllbRsLFV9NzLh+iTnWdk/sJKX3x1nB7/+xd8FgEVgTkAPqPopBlPORyOn4Z/ALgC39Tq+1bu+wq+JfwBBd9FuR8E8IVbRcyiNpEznLsAQzbQw8ObTwCMGX+AhozeT4/+vZo+2H5aZi2stevzY1Q07lNeDcRnYu0BAmATZXf9lNpFvTDI4XD8LHwDIEjgm+EP036+i1bfXT/fG/g5+I3A3zpyFnerjs07AIaPreIBMG/RcTp1KjxKfW9UvmQ/dXlwKx8sTMvfTOkFm+kPfylM0uEPswCwDb4F/D6V++76+Wb4TdBbgO+q1XcHvnWrb6fc9x58O60+hz9Cc3MNgKIJB2jw6P30zxcP0e4952SemqQOHz5LTz/3FcWlf4A1CfsuuujWu0I+DegUACFYvmvV6puh9y/4Jvj9Bn5gy30j+M01AIonHqBRZVpf//35x6jW3pS9W7HTp+ncjl10esESOvGPF+nI4CI6lNubquNzqToynaqjMqg6MoOqY7LoUGZ3Otx3GB1/9Bk6NXMOnd3yIdXVHJJ/pddavvoYJWYtnK+Df4k+EBjiAHAFvqnVtwu+dbnvK/iW8LsF30WrH4LluzL03oJvDIDWEe9oAdB/cZMOgOJJ2gh/6ZSDtO0j3/v65z7ZSSdefIMOd3+YDtzdlvb9+vdU+ZPLaa/jYu7KH19KleddRpX/dzn/+3r/+FLa67iE9jp+o33PL6+lqhvvpZq0LjwUzqzZQOysb1XJsWPHv5gzZ060juHPQxcAaeUVSdlrzdB7CL7LVt+Xfr4XrX5z6ufbgf+BDjNtBsDXDQEwLjwDAHP6GOjbt9/7Zr929w904vnXqDo6k/ZddIMO+yVU+bOraN+F1/MQ2PebGz3zRTdQ5S+u0YPhN1T50yvpwJ870rHSR+jch5/Ih2BbtbW1J3fv3t1JRxHw/0jCM/CK5QGwxhJ8l/DbAd9lq99c+vnBL/eN4LfqOJPbHACrm2QADBlTRU8/f4gOH/FuIc+5j3bQkf4jad8Vd2it+3mXacDLMPvDqCR+eiUPg30XXEc1ifl0euES+ZBs6+jRo/1lLoOm2NRFS+oDwB34Lst9O+AHq9xvfv18K/DdB8AHTSYAAP+/Xzvs1YIegI8SX2vtAeS1ZmAD6QtvoMofXUqVP7mMjyWcnlsuH6ItnT17tkhmMyiKTV20KDlrrZfg+7Hc9xl8F61+CPr5VvDbAt8F/Br4ZvhFALSKeIf4m4FcBMDwovANgCFj9nP4z53zDH529BgdLZ7CW2MO/q8C1NrbNaoCjBf8+FI6lNOLzu38XD5kt6qtrS2V+Qy4YlMW/TM5e4Mt8F22+r6A70W5H6h+vutWP7T9fBn6evg7zqT728+gtlFvU363d6hn/wrqMxABsFELgFEiAL4wBMCesAgADPgNLdpPTz9fQyc9nN8/PWcRHbizNe11/JqX4PsuvskMZKjMA+li2nfJzXTskaflQ3crxlhwuwNxKeVpSVlrvQPfj+W+CXoL8M2tvj3wrVt9O+CHV7lvBP+BDjO472s3k6IS3qTOPWdSr/5Lqc/ANYYA+JiGjt7lHABloQ8AwI8HeTDgd+SoB33+2jo6WjRJG6n/vyvCC3yjL76Jzxz84LiIqpMKqPb7H+QzaVSMsRyZ04ApKen9n8emLPwuIXOlJfzuyn1fwbeE3yb4Jvhtge+i3G9i4Avf3+4dSsl8nbr2fo96DVhGfQeuoQFDNhkCwFABlBoDoDJkATCqVJvq23/A/mg/IMLIPm/1Mbh3sQV4YWhUA/uv+xOdLl8mn5JLMcbOnD17tpXMasAUk7KoO55ewmu27YJvht9Gue8OfAv4A1XuN6l+vgv472s7izrEvEG5nd+gbn0WUO8Byw0BsI0Gj/qEho7ZRcPHfkEji7+hUaXfhzwAsMIPi3w+2mF/nh/z+VW33q/19S0gC2ujGjj/Cj4NefKN6fKpuRRj7BvG2G9kVgOmmOSFb6XkbOYhYAm+y1Y/MNN6gQLfdavvfT/fNvwW4HvT6mst/yxq1eEtSs16gTr1mEk9+pZT74dWUN9Ba2nA0M00cIQxAL4MmwDA8t65C4/J97tLnVm7kfZfdZc2rReuJb87IwSwjuC8y+j40y/Ip+hSjLHZMqcBU2zs/PNjUhfPSs7eSHFpS22A73m5b4LeAnz/lvt2wG865T53+5l0f7t3qVWHNykh9Vne+nftPZcPAD740ErqN2gdDRi6hQaO+JAGF+6wDIAx4/aGJADwYA/W9ttd3nt23SYOUFj39+0ax3/BdbyKOT7tOflUXYoxNkxmNaCKSakojEtbeigpC7sEraK41KUUm1pBsalLdOPPFRSbojnG5MWakxscbXI5RSc5O8roRHgRd6TshIUGL6CIBLzgU3c8vMBgbBGOrcJ1xxmNrcPFNuHzqEPsPGofM5e/bbdd9Bwnt4163+Q2UdiR15VnU2s4wtqtOsLvWvoBvrpPW+Hn5Paz6P52s+n+djOobcRLFJ/yd8oqeJk69XiXuvdZQD37L6EH+V4A6+mhYVto4MjtNLjwUxo65jMaMfYrGlnyLQ+A0SEKADzRB1fus7eEFuv29195V/OA3+hfXUd7f/RbOvna/+RTthTGA4joVpnTgCoqac41sWkVo2OSF6+ITl70Q3Tyouqo5IXVUckLqqOSnB3p9N/zq6MSGhzpyvFz6x0hOw6ew91Rdiz8fr07GB1j9Hvc7WVHa24X/V5Nu+h3a9pyv1fTNnr2obZRsw+1jZx5rl3UTGobham1GdQ28h1qY2FsONk6wpXfplZwRwt3eJse4P6fa7d/S3MH/Wt77e9adXid2kY8T5FxT1Bi2jTKzHuZT/2h9e/edxEfAGyYAtRXARbqi4D0AKh/DmAcZgAqOfzBCgCU/gsqjsv3t6Vq9+ylqtvuo8ofN+Gy35X5DME1fCXh6XmL5VO3FGNskcxo0PRA8nsXxGSt+01MzKIgeXr9n++z/DfN9/ngv0S+fvEf7n/80tvuKbriutt7Xvu769NuvuqGjJv+eG+vp9pHlVDrDiM1tw+CO4ykNh1G6S6kth1HU9uIMdQuYiy1jyymDlFlFBEznqLjJ1J8yiOUkvkPysx/lfK6vk2de86mbg/Opx79Fmv9/4Fr6wcAMQNgXgOgLwLiAaC1/kUC/gAGwMgSbcrv9Gkb8/21tfyJPD7g19zgF0YI/PRK2n/prXTui6/lK2ApxliuzKaSf4SnsLAx46+vvfbPCZFx485Fx0+gqLgyP3mca8fD47nxmdEJEykGTpxMsUlTKS75EUpIeZyS0p6ilMxnKT3nRcoueIPDj91veevfZ6Fe/mv9f17+o/8vBgCL9BmAEC0C4qP+RVX0sc1R/6PFU2mv4yIzNM3NF9/EuwIH2yUTO+1+ezPG2O6ampoL5ZtXyXvh6SvAj2exL3Y4HFc6HI4bo+InbUvJfI4SUqcF2E9SQtqT/Gti2lO6/05J6U9TcsYzlJL5T0rNeo7Ssl+gjNyXeKuf3ek/lNflbSroPpO69HzP0Povdyr/Rf9/2JjPTAOAwZ4BwMDfv1629yw9HqjZG8iHeMLQCLujI8fJl8JSjLGx8k2s5L3w6OVP9GexsSvL7xwOx2Wt2w99JDPvVQ5hcsY/guB/ctjRwsOpWf+itOznKT3n3xr4ea9QVsHrlNPpv5Tb5X+U320GL/279p6n9f37LzWM/m+uL/+xAGgYngFw6v8HdwAQrT+e79/5uY0W7thxqrqjVfMb9HPnC6+nyvN/R2fXb5YviUmMsarDhw8Hb21AMxcC4Dx9U0aUVpc5HI6rrrjmb9Epmc+dRLkNGAPhNPE1+3mDX+DQ43Mzcl+mDICf/xov+XM6v8lb/vzuM6hTz3epay+99O9Xoff9teW/D6H1N07/8f6/ofwP8gAg4H/2RXutP56t56v8ftOC4IcxHnDepbwrYGd+lDE2Ur6RlbwXAgDbMl/gcDh+63A4roXjkx9flNd1Om+BA+OXnZ33Cm/pUXlk5r/GW3yU+wCft/pdp/OyX2v5Nfh56T9gOX/6r37qjy/+0Qb/6st/ffrP6hmAQA8AYoMPO7v4nvv0M9p30fXagz0yIC3ECL8TL7wuXxqTGGPfMsbQaCn5QWIcAHuzYRzgKowF/Pkv3R7EQFt2wX84jP7zG7xFd3In+D+8xOdlfue3OPT4fEzzAXzM9Xfp9b5e9gP+Cuo1YDmf9+/LS3997T/v+xtbf8Pov976B6v8LyyroqlPVtOZM+5H/g/1eLh5j/rbMGYFqm69j9gx96skGWMZ8o2s5J3kcYArHA7H9Q6H4/a03Bc/6tJ7Docxt8vbfjHKeIBd7/r/ns5beQ34GfXQo8WvB7/PAr7cFyP+Wsu/ivf7+/NpP730H7VDa/1F379Yb/3F6H8Qy39s8jF3kfubGc/N82f5W9DAnyvzKuD5V+VLZBJjbJ58Iyt5JzEOgG4AxgEu1bsBV7frMHwUgAOImHLzr/E7G9y5pwZ7557vacD3msOhxyg/L/cBPm/1l/EBP4z49xssWn4NfjHvr5X+mPpzbv3l0f9Alv8Y/MMTf9/tPivfuyYd6T+iaT7kEwDzvQb/0I7YiZPyZXISY+wkYwzVqpIfhAA437BFMy7sjQ6H4+68zm/vQmuLfjeADIQBeYMXcOC791nEoUc/Hy0+yn0M9qHVx8M+ePmnNuL/QQP8+rLfhtJf6vvz8n9fUMp/LPz5+79qqM7No/61e/fR/stuC/42XmFsPD58asYc+VKZFPSNQ5qxRDcA6wFEN+AGVALtIgpHoY8NEDmQ/jJ+n8Fo3bn7L6Ge/Zfylh7BA+ixwActPsDHYB9W+mHAD9N9A0ei7NdafvT7hwF+Y+lfZt33D2TrD2Obr/nl7pf9nnjhNdX6S8bioEPZPeVLZRJjbKF8Iyt5J+N0IFYEohtwjcPhuNnhcNzVqefsbQ8N+4AvtgGQgTDKeu6HV/FRfQ78wDU69Ojno8UX4Out/siPtQE/Dr9o+fWHfvTSv5DDb1j6K7f+AQoA7Paz6wv3c//VUZl8dx8ZghbtX11H+y69lWq/2y1fLicxxmqOHDmCgWslP0ieDcCqwN+jEvhrq369UG4DQgDpL/fjXtfgwfB6Xt5jTh8tPT5Xg36rAfyP+DJfXvKP3lXf5x8x9ut6+EcZ+/1Bbv1HjztAEx47SCdOND76z6f+1OCfpVEVnXjuFfmSmcQYi5FvZCXvZJwNuEhfFITBQDyGeXN+t+nvobRGKwwo/eWHuLdwyIUF7NwjtnHosbQX/Xwj+Fqrj9H+L3mfn5f9hpbfGv7At/5Y/PPCa+4X/2DOW5X/1ubdgJxe8iWzUpl8Iyt5LzEYiEVBxsHAW373uz9FDhi6+QBaWw1KT/2hewNy7o8068CjzMe6/iEceg18TPNhkY+2zFdb6adN97lo+ccHB34Y/f955e6n/w51HUB7f3SJ6eZXvpEqf3E1Vd3yN748ujExxvB+QSU/CVWAeDgIg4GXG6qAG2OTpo4FZENGf0qDCwGmNwbMO/h8ff2fdcCFMaDHB/UAvBH6MZ/zfj4Hn7f43+gl//e85Oej/SGGH8aTf1u2Nb76j508RVV3tdFe12UBQIv3Rb/n1+bMuk3ypXMSY+xLIkLlquQHGdcEYDAQS4NRBWAs4A4sDur64IIFYycebIDTW9dDrRl/FpCjda+HXTcv88d+VQ8+b/HrW32Ar031uYI/0NN+wpj/Lxx3gL7b3fiuP+c+2cXf5IO36phufmVuO+MAjLHTp06dwsI1JT/J+IiwqAKuQzcAAXDxZbe2HzTy4+8BlNYae+IvTdbA1uGu/6qBXt/K17f0YoBPK/UBvrnVdwN/gAMAW36Nm3rQ7fv9sBMO3+TTmxd1thBjPcCRocXypTOJMdZGvomVvJexCjCOBWBdAKqAWx5oPbBHYdmeMwBNA/Rbz13i2vWg67ALG6EXg3zW4LsY8Asw/PCosip67OlqOuvmNV/YGZe/PcfixlfWjO3QalI6y5fOJMZYgXwTK/kmVAHGGQExFoB1AXcjBNJyXphaOuUoB9AIqS/WADdawO7c0tdDr5f6TuCHEH54RIm26687HRk4mr+yW77plRtc+bMr6cA9HfHWUPnyOYkxNly+gZV8k6gCjDMC2CwEfS0MCP4B1UC3Bxe8OfHxMxxII6iemPfdBdzCOuRG1wPv1NobwXdR7gcJfGFMAb70xmH5HjUJK93wEk35plduMDYO3X/9PVRXXSNfPicxxibLN7CS7xJVAFYHogrAgODV+oDg7XolcE+/wesrJj1xjoM52gipP6yDbrRVS+8S/CDDD+ONP/+dfkS+R02qjs3WxgAsbnxl3VgReMUdVPut2xWBz8o3r5LvQhVgHBDENkyiK3CTw+G4EyFw3nkXPDBw5PaNk6bVmmD1xFprLgEuWwJeswX0IQBfGAHwv5lH5XvUpIMdUrStv+SbXrnBWCX521vo3GeY6XMtxtiL8s2r5B9ZDQhiiTC6ApgVQBVw90UXXd1u0KiPt0yeVucGVn/YAvYwAF8YawDemW0jANomqQBwZwTAJTfzJdNu9Kp84yr5T8YBQbFfgOgKiPEAPQQ+2TLlSeKQmsG1Y/xcg01wu7IFiKEyAuDtWTYCoF2yCgB3FgGw83P58jmJMfayfNMq+U+iK4ABQePaADwtiGXCtzkcjj/Wh8CIj9YgBIonHjSD6i9bgBcuRhfgzXdsjAFEZainAN0ZYwCX3Ua1X30rXz4nMcb+Jd+0Sv6VsSuApwXl8QAMCiIEUA3c32/w+rmTpzEqmXzIAO4BG24akDdmvAPg1TfdB0BNWhc1C+DGlRdcS/uv+QPV7T8gXz4nMcYel29YJf9LdAXEeAAeGcbUIFYJYn0AFgkhBP6E2YFuDy7697hHT9L4R09Q0cSmC7Snxj4Adl4CcrjXYLUOwI0rf341HbijFX9uojExxsbIN6tSYGScGsSzAsZBQWMI/BkbiaRmPz9m7MSDRyZNqzOB0lyNfQCffNb9VmDHJj+pHgV2Y3SRqqMz5UtnEmOsl3yjKgVGxqlBMSiI9QHGmQGEALoC92Kq8N6/9cgbPvbr7VOeIiqZcpjGNvNqQGwGcvxE4wlwavps/sy7fNMrNxgV0uE+w+RLZxJjLFq+UZUCJ+MqQbFUGDMDeF7AGAKYIkQI/OG8837autdDy14vnXK4buLjZ03QNCePmaA9EVi5r/GnAc9u+oCXuPyJQIubX1l7GvDYo8/Il85JjLFaxhjGoJSCKGMIYGZArBQUIYDuQP1qQb1LcHdE7LgBo0q+2zn5SaKyqUebbTWAgcCPP218P8C6gzV8mSuWu8o3vvKN/ClJrJQ8Pb9CvnROYoztJSIMTCsFWa4qAeOYAELgLn1c4C985eD5v2zbrc+if42ddPAogoDPFDSzIBhadJBWrWv8aUCoJilfLQd25Quuo/1X3kl1lfvly+Ykxthq+cZUCp5cVQJidgBThFgngBDAuAAqAXQL7r7j7vSsh4Z98H7x5JparCAsmVxjAqmpuXjSQUIXZ2TpIXrtzT2NT15jIHDKU2og0IX5AGBMlnzJTGKMPSPflErBlVwJYGBQPD2IdQJisRB/dkCfJkQ1gK9/at1heM9BIz9eUjypum7yk4xKpxwxgRXuRnjhgagJj53CzsTboxL/PiwhISq9tvZco6+3ObN6vbYaUG0KYjJeEXas7FH5kpnEGMuTb0il4MsYAmKKEOsExIpBLBvmOwoZqgGMDSAI+LRh6w5Dew4Yunnu2IkHjyEIxj96ioonVZtgCyeXPXKMcKwIgKFjdq1PzngGr61uJbo9R44c+Vi+YY1ip07x12DhuXcZgBbti27gA6QYKG1MjDEMtGCjGqUwkAgBTBEiBLBYCCsGsb24GBwUXQJRDYg1A6IiuOeOu1OyevQrf2FUyXdfjXv0BGFF4bhHjvPyWgYw+D5IpVOPEp58nPjEWRo9bt/+fkM2zGzTcURvh8PxVz3YcC7o5lz3xRdfvCTftLKOlkzhrZ0JghZsVEV4WIqY23GUzfJNqBRaiXUCYsUgRmeN4wLoElhVAyIIABG+4u86xCU9OqT/4I2zC0v37EEIoLWd8NhpKuXrCYITCBikHP/oScI4BTY/KZqwr2bQiO1LM/NeGXf55XclGFY/CvDxZxz/dW+99VZX+Y6VdXb7Dr4FttoctMEIxONPPS9fKpMYY5PkG1Ap9DKGgBgXMHYJjNUAnibEmgFjEIiugege/OlnP/ttdHTC5CG9B6z877CiLz4pGr//xPjHTvFAmPjEOQ4oxg6KJ2Eg0ZtgOMi7G1iohKDBQB4qD7TyYyceODey5LuvBwzd+H5azr9Lr7++VYpY36B/xXEitAT4qGxQ4dx0/fXX33LmzBm3g4F8cxD1XIBmrP/HA0C7f5Avk0mMMdwrSmEqqy4BniRENYCXj2JsAP03TBeiWyAHAYAS3QMRBnDrW25PyE5Me2p09z4LXhk48qNVI0u++2r0uL3HiyfX8AoBoYBwgFGuT3pC8rRa3qLzf3+iliY8foZKpx7Bm4NPjSr5fs/gUZ9s7jVg2fTM3Jcn3Pu3Hl1+9KMfdTQADuhRqeArbkDxEJQAH+eCc0Kl88v9+/c/J9+4sk4vWqoFQEsfDLz4Jt76Hx1eKl8ikxhj24hIvueUwkxylwBThagGMDaANQOiW2AVBGKMQFQFxjDAnwV4f3E4ftTxhhvaZLZqP7xvQspTRbmd33yy64PzX3nwoRXv9B20bn6/wRsX9x+ysbzBGxY++PCqWd36Lnwjv+s7/0jN/FdZx8ixD992Z0ouqg2Hw3GfDrxxjEKU+DgW8W/4fByrEXzMemAKFJXOLxYsWNCOMdb4umDGqLp9sloTcMF1/GvtV9/IV8ik2traYfLNphSeEiFgrAYwNoDpQnQLMEiIxUMiCIxdAzFYaKwK+GChAUy0xkY4BZiwsYrAv4uS3fi9wsbvNf5O/J0MPY4J4OMYjS2+AB9dHUyF4hzPq62tXS3fwLJOzy3Xng5sqVWA3vofGVwkXxqT6urqjjPG0HgoNSFZjQ2gW4BBQsAiggBdA4wR8HcSGqoCYxhYBYIIBSPowgDaaOO/yaAL2I3AW0GPY0NYIbQQXkbw0dVBpYOKx3Hs2LFs+Sa2Uk16Vy0ELr7JDEgzN6b9+LP/blb+QXV1dS/JN5dS0xBCoLEgQEUgugbYdgwtqqgKRBhg9sDYTZBDwRgMdm2sBATsAngEDz7TCL1o7RFWOFaElxF8nBO6PKh4HJs3b/5JXV3dDvlGlnVu1xfaw0G/vNYESHM3Wv+TL/1HviQmMcbOMsbw/79SE5YIAnQLjEEgugYYI8BgIVpUVAXGMEBlgJJbDgSACmCNwSAHhLE1N1r8HH4Hfwei/rv5q9EtoMcxYSATYYXQQnghxIzg49wQdDhPR21tbYF8M1tJWx58oQmQZmte+l+iPffvbhMFLQDelG8mpaYtMT4gggBjBGKwUFQFIgxEZYCS2xgIAFSEAqCFAbAICFcW34Pvx88K2PE78bvRFcFn4TNl6EVrj9ByCb4QEZ3HGNsu39Am1dZSdVw2VbaQrgDeALz/itup9suv5SthUl1dHVp//P+l1MwkVwQACUCJqkCEASoDMV4gAgF9bwCKlhmhAGhhAIxWWxhQC4u/w/cI0PGzgB2/B78TvxvA47MQQAJ6VCgy9DhmHLs4D0sxxjrKN7WVar/fQ/uvuosqf/q75h0CF97AW/9Ts+bKl8BSjLFH5Wuq1PxknDWQwwCVAUptYyCICgEtswgGgAuA0Wo3ZgE5jJ/D78DvQsjgdwvg8ZlG6FGpCOhFa+8SfKMYY2/IN7aVTi+ooMrzr6BKjAc0xxD49e95V+fo6AnyqVuKMYa5QfXcfwuSccDQGAaimyACATcFAAWoMIIB4IpwaMwCchg/h59HuOD34XfjM/BZckvvEfRGMcauqKurc79rKBGdfOVNbdswbI8tA9TEvddxER3uMVA+ZZdijKXL11KpZUmEgRwIokKARTCIcBBGSMgW/ya+Hz8rYEfIGIH3CXpZjLHe8g3uSsef+Kf2sBBekmEBUlM0Wv6atM5E5xrfNk2IMTZDvoZKSsYKQYSCCAZhERCubPxe8fMCdr8BbyXG2H/lG92Vjk39u7Y+4IIm3h3gZf9FHH52/IR8mpZijGF0EBWaklKjErDKFjBbWf7eoAn9WcbYTvmGd6UTz7/GH5PFqHmTDIELr+ct/6HuD3vS8teePXu2jXztlJSahRhjf2KMnZZvfFc6NXMuh58/ONRUQgDH+7OreAVzdNQ4+ZQaFWNshHzNlJSalWpra3PlG78xnft4Jx18II6X0mhV911sAV0YmXddLr+dTr39rnwqjYox9oJ8rZSUmqUYYwNkABoTXpV15OFCvnFmWD5BiFb/51fzDU+rI9L4EmdPxBibKV8jJaVmLcaY+4fgJZ1ZslKvBn6tjQ3IIIbCv7qOHw8e7Dnx7Ct2tvVyUl1d3XLGGGZhlJRalhhjk2Ug3ImdPUvHn/wXVf3+Xt7ihmyD0Quu1bY4//WNdGTASFs7+shijC0lIqzFUFJqmWKMuX8ZnoXqqg/R8WnP8bfp7nVcrA0UBnrtAHbv/b8rtHUKl91GRwaNoXM7P5cPzZYYY7NUy6+kpIVAV0yByZDYETt6jE7+dwbVpHamfRffrFUFP76UKn9xje+bjeDnL7iOjz1o1cZVdLBVPB1/9Bmq/eY7+VBsSw34KSlJYoxF1dXVud1QtDHVfv4V310XG41U3Xgvf7gI4GJkHoOHALgSi4uw1BgzCqgYxNcLruW7FVf+H2D/rQb8eZfR/ivu4AN7R4sm0Zk1G+WP9EiMsXOMsVHyuSspKWkh8DvG2BwZHG9UV3OIzqxYS8f//gKfQahJzKcDd7flg3X7LrtVW1dwyc2075KbaN9vb+FPI1bdeh+HHWv2j035O51+fyHVfrdH/tVeiTH2BWOsg3zOSkpKkhhjRZ4sGLIrvJmoruog1X75DZ379DPef+f+7Euq3buPdycCIcbY24wxPHWppKRkR0T0Z8ZYuQxTUxJj7HPGWI58bkpKSjZVW1vbgzH2vQxXOAvVCzbzUFN8Skp+EBFdwhgbzxirkmELJ2EmA3v4McawD6OSkpI/hc1FGGPF+m45YSPG2BHG2IvotsjHrKSk5Gcxxi5gjOUzxuYzxk7JQAZLjLGteIKPiLC/opKSUrDFGLuJMTaQMbaIMVYjQ+pP6Xv0b6mrq5vKGPubfCxKSkohFBFdzhhLxGu09UD42pfpRMZYJWNsHWPsWcZYZ8YYtlJXUlJqCmKM/YwxdiMW4NTW1mK58WgiQuuN/vqrjLFXxFfG2DTGWAljrC9jLI4xdpcaxVdSUgpb/T8rSajVXRe1qQAAAABJRU5ErkJggg=="
    $IconBytes = [System.Convert]::FromBase64String($IconBase64)
    $IconStream = New-Object System.IO.MemoryStream(, $IconBytes)
    $DecodedIcon = [System.Drawing.Image]::FromStream($IconStream)
    $BrandMark.Image = New-Object System.Drawing.Bitmap($DecodedIcon)
    $DecodedIcon.Dispose()
    $IconStream.Dispose()
    $Header.Controls.Add($BrandMark)
    # Same icon for the title bar and the taskbar
    $WindowIcon = New-Object System.Drawing.Bitmap($BrandMark.Image, 48, 48)
    $Form.Icon = [System.Drawing.Icon]::FromHandle($WindowIcon.GetHicon())

    $Title = New-Object System.Windows.Forms.Label
    $Title.Location = New-Object System.Drawing.Point(92, 25)
    $Title.Size = New-Object System.Drawing.Size(510, 36)
    $Title.Text = $Messages.HeaderTitle
    $Title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 18)
    $Title.ForeColor = [System.Drawing.Color]::White
    $Header.Controls.Add($Title)

    $Subtitle = New-Object System.Windows.Forms.Label
    $Subtitle.Location = New-Object System.Drawing.Point(94, 65)
    $Subtitle.Size = New-Object System.Drawing.Size(510, 24)
    $Subtitle.Text = $Messages.Subtitle
    $Subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $Subtitle.ForeColor = [System.Drawing.Color]::FromArgb(205, 216, 232)
    $Header.Controls.Add($Subtitle)

    $InfoCard = New-Object System.Windows.Forms.Panel
    $InfoCard.Location = New-Object System.Drawing.Point(24, 126)
    $InfoCard.Size = New-Object System.Drawing.Size(852, 78)
    $InfoCard.BackColor = [System.Drawing.Color]::FromArgb(232, 240, 255)
    $Form.Controls.Add($InfoCard)

    $InfoLabel = New-Object System.Windows.Forms.Label
    $InfoLabel.Location = New-Object System.Drawing.Point(14, 10)
    $InfoLabel.Size = New-Object System.Drawing.Size(824, 58)
    $InfoLabel.Text = $Messages.Info
    $InfoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $InfoLabel.ForeColor = [System.Drawing.Color]::FromArgb(40, 65, 105)
    $InfoLabel.AutoEllipsis = $true
    $InfoCard.Controls.Add($InfoLabel)

    $UsersHeading = New-Object System.Windows.Forms.Label
    $UsersHeading.Location = New-Object System.Drawing.Point(26, 218)
    $UsersHeading.Size = New-Object System.Drawing.Size(530, 26)
    $UsersHeading.Text = $Messages.Users
    $UsersHeading.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
    $UsersHeading.ForeColor = [System.Drawing.Color]::FromArgb(45, 55, 72)
    $Form.Controls.Add($UsersHeading)

    $AddUserButton = New-Object System.Windows.Forms.Button
    $AddUserButton.Location = New-Object System.Drawing.Point(738, 214)
    $AddUserButton.Size = New-Object System.Drawing.Size(138, 32)
    $AddUserButton.Text = "+  " + $Messages.AddUser
    $AddUserButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $AddUserButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(205, 213, 224)
    $AddUserButton.BackColor = [System.Drawing.Color]::White
    $AddUserButton.ForeColor = [System.Drawing.Color]::FromArgb(45, 80, 145)
    $AddUserButton.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Form.Controls.Add($AddUserButton)

    $UsersPanel = New-Object System.Windows.Forms.Panel
    $UsersPanel.Location = New-Object System.Drawing.Point(24, 254)
    $UsersPanel.Size = New-Object System.Drawing.Size(852, 370)
    $UsersPanel.AutoScroll = $true
    $UsersPanel.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
    $Form.Controls.Add($UsersPanel)

    $UserRows = New-Object System.Collections.ArrayList
    $RefreshRows = {
        for ($rowIndex = 0; $rowIndex -lt $UserRows.Count; $rowIndex++) {
            $UserRows[$rowIndex].Panel.Location = New-Object System.Drawing.Point(8, (8 + ($rowIndex * 124)))
            $UserRows[$rowIndex].RemoveButton.Enabled = ($UserRows.Count -gt 1)
        }
    }.GetNewClosure()

    $AddUserRow = {
        param([string]$Username, [string]$WebhookUrl)

        $RowPanel = New-Object System.Windows.Forms.Panel
        $RowPanel.Size = New-Object System.Drawing.Size(810, 112)
        $RowPanel.BackColor = [System.Drawing.Color]::White

        $UsernameLabel = New-Object System.Windows.Forms.Label
        $UsernameLabel.Location = New-Object System.Drawing.Point(14, 10)
        $UsernameLabel.Size = New-Object System.Drawing.Size(240, 20)
        $UsernameLabel.Text = $Messages.Username
        $UsernameLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
        $RowPanel.Controls.Add($UsernameLabel)

        $WebhookLabel = New-Object System.Windows.Forms.Label
        $WebhookLabel.Location = New-Object System.Drawing.Point(270, 10)
        $WebhookLabel.Size = New-Object System.Drawing.Size(470, 20)
        $WebhookLabel.Text = $Messages.Webhook
        $WebhookLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
        $RowPanel.Controls.Add($WebhookLabel)

        $UsernameInput = New-Object System.Windows.Forms.TextBox
        $UsernameInput.Location = New-Object System.Drawing.Point(14, 36)
        $UsernameInput.Size = New-Object System.Drawing.Size(240, 27)
        $UsernameInput.Font = New-Object System.Drawing.Font("Segoe UI", 10)
        $UsernameInput.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $UsernameInput.Text = $Username
        $RowPanel.Controls.Add($UsernameInput)

        $WebhookInput = New-Object System.Windows.Forms.TextBox
        $WebhookInput.Location = New-Object System.Drawing.Point(270, 36)
        $WebhookInput.Size = New-Object System.Drawing.Size(526, 27)
        $WebhookInput.Font = New-Object System.Drawing.Font("Segoe UI", 10)
        $WebhookInput.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $WebhookInput.Text = $WebhookUrl
        $RowPanel.Controls.Add($WebhookInput)

        $RemoveButton = New-Object System.Windows.Forms.Button
        $RemoveButton.Location = New-Object System.Drawing.Point(14, 72)
        $RemoveButton.Size = New-Object System.Drawing.Size(100, 28)
        $RemoveButton.Text = $Messages.Remove
        $RemoveButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $RemoveButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
        $RemoveButton.ForeColor = [System.Drawing.Color]::FromArgb(145, 55, 55)
        $RemoveButton.Tag = $RowPanel
        $Row = @{
            Panel = $RowPanel
            UsernameInput = $UsernameInput
            WebhookInput = $WebhookInput
            RemoveButton = $RemoveButton
        }
        [void]$UserRows.Add($Row)
        $RemoveButton.Add_Click({
            param($Sender, $EventArgs)
            $RowToRemove = $Sender.Tag
            [void]$UserRows.Remove(($UserRows | Where-Object { $_.Panel -eq $RowToRemove } | Select-Object -First 1))
            $UsersPanel.Controls.Remove($RowToRemove)
            & $RefreshRows
        }.GetNewClosure())
        $RowPanel.Controls.Add($RemoveButton)
        $UsersPanel.Controls.Add($RowPanel)
        & $RefreshRows
    }.GetNewClosure()

    if ($ConfiguredUsers -and $ConfiguredUsers.Count -gt 0) {
        foreach ($ConfiguredUser in $ConfiguredUsers) {
            & $AddUserRow ([string]$ConfiguredUser.Username) ([string]$ConfiguredUser.HAWebhookUrl)
        }
    }
    else {
        & $AddUserRow $DetectedUsername ""
    }

    $AddUserButton.Add_Click({
        & $AddUserRow "" ""
        $UsersPanel.ScrollControlIntoView($UsersPanel.Controls[$UsersPanel.Controls.Count - 1])
    }.GetNewClosure())

    $InstallButton = New-Object System.Windows.Forms.Button
    $InstallButton.Location = New-Object System.Drawing.Point(762, 654)
    $InstallButton.Size = New-Object System.Drawing.Size(114, 36)
    $InstallButton.Text = $Messages.Install
    $InstallButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $InstallButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $InstallButton.FlatAppearance.BorderSize = 0
    $InstallButton.BackColor = [System.Drawing.Color]::FromArgb(45, 100, 210)
    $InstallButton.ForeColor = [System.Drawing.Color]::White
    $InstallButton.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
    $InstallButton.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Form.Controls.Add($InstallButton)

    $CancelButton = New-Object System.Windows.Forms.Button
    $CancelButton.Location = New-Object System.Drawing.Point(644, 654)
    $CancelButton.Size = New-Object System.Drawing.Size(110, 36)
    $CancelButton.Text = $Messages.Cancel
    $CancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $CancelButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $CancelButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(205, 213, 224)
    $CancelButton.BackColor = [System.Drawing.Color]::White
    $CancelButton.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 80)
    $CancelButton.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Form.Controls.Add($CancelButton)

    $Form.AcceptButton = $InstallButton
    $Form.CancelButton = $CancelButton

    while ($Form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $ValidatedUsers = @()
        $SeenUsernames = @{}
        $SeenWebhooks = @{}
        $ValidationMessage = $null
        foreach ($Row in $UserRows) {
            $Username = $Row.UsernameInput.Text.Trim()
            $WebhookUrl = $Row.WebhookInput.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($Username) -or
                $Username -match '[\\/:*?"<>|]' -or
                $Username -match '[ .]$' -or
                $Username -in @(".", "..")) {
                $ValidationMessage = $Messages.InvalidUsername
                break
            }
            if ($SeenUsernames.ContainsKey($Username)) {
                $ValidationMessage = $Messages.DuplicateUsername
                break
            }
            $SeenUsernames[$Username] = $true

            $ParsedWebhookUri = $null
            if (
                $WebhookUrl -notmatch '/api/webhook/[^/]+$' -or
                -not [System.Uri]::TryCreate($WebhookUrl, [System.UriKind]::Absolute, [ref]$ParsedWebhookUri) -or
                $ParsedWebhookUri.Scheme -notin @('http', 'https')
            ) {
                $ValidationMessage = $Messages.InvalidWebhook
                break
            }
            if ($SeenWebhooks.ContainsKey($WebhookUrl)) {
                $ValidationMessage = $Messages.DuplicateWebhook
                break
            }
            $SeenWebhooks[$WebhookUrl] = $true
            $ValidatedUsers += @{
                Username = $Username
                HAWebhookUrl = $WebhookUrl
            }
        }

        if ($ValidationMessage) {
            [System.Windows.Forms.MessageBox]::Show(
                $Form,
                $ValidationMessage,
                $Messages.InvalidTitle,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            continue
        }

        return @{
            Users = $ValidatedUsers
            UiLanguage = $UiLanguage
        }
    }

    return $null
}

$DetectedUsername = Get-InteractiveUsername
$ConfiguredUsers = @()
$PreviousSettingsPath = "C:\Scripts\TeamsStatus\Settings.ps1"
if (Test-Path $PreviousSettingsPath) {
    . $PreviousSettingsPath
    if ($TeamsUsers) {
        $ConfiguredUsers = @($TeamsUsers)
    }
    elseif ($HAWebhookUrl -and $LocalUsername) {
        $ConfiguredUsers = @(@{
            Username = $LocalUsername
            HAWebhookUrl = $HAWebhookUrl
        })
    }
}
$UiLanguage = $DetectedUiLanguage
$InstallerValues = Show-InstallerDialog `
    -DetectedUsername $DetectedUsername `
    -ConfiguredUsers $ConfiguredUsers `
    -Messages $Messages
if ($null -eq $InstallerValues) {
    exit
}

$TeamsUsers = @($InstallerValues.Users)
$UiLanguage = $InstallerValues.UiLanguage
$Messages = Get-TeamsMessages -Language $UiLanguage -Root $PSScriptRoot

$Path = "C:\Scripts\TeamsStatus"
if (-not (Test-Path $Path)) {
    New-Item -Path $Path -ItemType Directory
}

$ServiceName = "Microsoft Teams Status Monitor"
$ExistingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($ExistingService -and $ExistingService.Status -ne 'Stopped') {
    Write-Host $Messages.ServiceStopping
    Stop-Service -Name $ServiceName -Force
}

$SettingsPath = "$Path\Settings.ps1"
function ConvertTo-PowerShellString {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}
$SettingsLines = @(
    "# Generated by the Teams Busy Light installer."
    "`$TeamsUsers = @("
)
foreach ($TeamsUser in $TeamsUsers) {
    $SettingsLines += "    @{"
    $SettingsLines += "        Username = $(ConvertTo-PowerShellString $TeamsUser.Username)"
    $SettingsLines += "        HAWebhookUrl = $(ConvertTo-PowerShellString $TeamsUser.HAWebhookUrl)"
    $SettingsLines += "    }"
}
$SettingsLines += ")"
$SettingsLines += "`$UiLanguage = $(ConvertTo-PowerShellString $UiLanguage)"
$SettingsLines += "`$TeamsLanguage = 'auto'"
$SettingsLines += "`$HeartbeatSeconds = 60"
Set-Content -Path $SettingsPath -Value $SettingsLines -Encoding UTF8

Copy-Item -Path "$PSScriptRoot\Messages.ps1" -Destination $Path -Force
if (-not (Test-Path "$Path\Translations")) {
    New-Item -Path "$Path\Translations" -ItemType Directory | Out-Null
}
Copy-Item -Path "$PSScriptRoot\Translations\*.psd1" -Destination "$Path\Translations" -Force

# Resolve the HA host via DNS servers configured on active LAN/Wi-Fi adapters
# and add/update it in the hosts file.
$HAHosts = @(
    foreach ($TeamsUser in $TeamsUsers) {
        ([System.Uri]$TeamsUser.HAWebhookUrl).Host
    }
) | Select-Object -Unique

foreach ($HAHost in $HAHosts) {
  try {
    $ResolvedIP = $null
    $ActiveAdapterAliases = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Status -eq 'Up' -and (
                $_.Name -match 'Ethernet|Wi-?Fi|WLAN' -or
                $_.InterfaceDescription -match 'Ethernet|Wi-?Fi|WLAN|Wireless'
            )
        } |
        Select-Object -ExpandProperty Name -Unique

    $DnsServers = @()
    if ($ActiveAdapterAliases) {
        $DnsServers = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.InterfaceAlias -in $ActiveAdapterAliases -and
                $_.ServerAddresses -and
                $_.ServerAddresses.Count -gt 0
            } |
            ForEach-Object { $_.ServerAddresses } |
            Where-Object { $_ -and $_ -notmatch '^127\.' } |
            Select-Object -Unique
    }

    foreach ($DnsServer in $DnsServers) {
        try {
            $DnsAnswer = Resolve-DnsName -Name $HAHost -Type A -Server $DnsServer -ErrorAction Stop |
                Where-Object { $_.Type -eq 'A' -and $_.IPAddress } |
                Select-Object -First 1

            if ($DnsAnswer) {
                $ResolvedIP = $DnsAnswer.IPAddress
                break
            }
        }
        catch {
            # Try next DNS server.
        }
    }

    if ($ResolvedIP) {
        $HostsPath = "$env:windir\System32\drivers\etc\hosts"
        $HostsLines = Get-Content -Path $HostsPath -ErrorAction Stop
        $HostPattern = "^\s*(?!#)\s*\S+\s+.*\b$([regex]::Escape($HAHost))\b"
        $MatchingIndexes = @()

        for ($i = 0; $i -lt $HostsLines.Count; $i++) {
            if ($HostsLines[$i] -match $HostPattern) {
                $MatchingIndexes += $i
            }
        }

        $DesiredLine = "$ResolvedIP`t$HAHost`t# Teams Busy Light"

        if ($MatchingIndexes.Count -eq 0) {
            Add-Content -Path $HostsPath -Value $DesiredLine
            Write-Host ($Messages.HostsAdded -f $ResolvedIP, $HAHost)
        }
        else {
            $UpdatedLines = New-Object System.Collections.Generic.List[string]
            $FirstMatchHandled = $false

            for ($i = 0; $i -lt $HostsLines.Count; $i++) {
                if ($i -in $MatchingIndexes) {
                    if (-not $FirstMatchHandled) {
                        $UpdatedLines.Add($DesiredLine)
                        $FirstMatchHandled = $true
                    }
                    continue
                }

                $UpdatedLines.Add($HostsLines[$i])
            }

            $UpdatedLines | Set-Content -Path $HostsPath
            Write-Host ($Messages.HostsUpdated -f $ResolvedIP, $HAHost)
        }
    }
    else {
        Write-Warning ($Messages.DnsFailed -f $HAHost)
    }
  }
  catch {
    Write-Warning ($Messages.HostsFailed -f $HAHost, $_.Exception.Message)
  }
}

Copy-Item -Path "$PSScriptRoot\Get-TeamsStatus.ps1" -Destination $Path
Copy-Item -Path "$PSScriptRoot\Languages.ps1" -Destination $Path
Copy-Item -Path "$PSScriptRoot\nssm.exe" -Destination $Path


Unblock-File $Path\Settings.ps1
Unblock-File $Path\Languages.ps1
Unblock-File $Path\Get-TeamsStatus.ps1
Unblock-File $Path\Messages.ps1
if (-not $ExistingService) {
    Start-Process -FilePath $Path\nssm.exe -ArgumentList 'install "Microsoft Teams Status Monitor" "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" "-command "& { . C:\Scripts\TeamsStatus\Get-TeamsStatus.ps1 }"" ' -NoNewWindow -Wait
}
Start-Service -Name $ServiceName

[System.Windows.Forms.MessageBox]::Show(
    $Messages.InstallComplete,
    $Messages.CompleteTitle,
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
) | Out-Null